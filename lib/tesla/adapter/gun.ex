if Code.ensure_loaded?(:gun) do
  defmodule Tesla.Adapter.Gun do
    @moduledoc """
    Adapter for [gun](https://github.com/ninenines/gun)

    Remember to add `{:gun, "~> 1.3"}` to dependencies.
    In version 1.3 gun sends `host` header with port. Fixed in master branch.
    Also, you need to recompile tesla after adding `:gun` dependency:
    ```
    mix deps.clean tesla
    mix deps.compile tesla
    ```
    ### Example usage
    ```
    # set globally in config/config.exs
    config :tesla, :adapter, Tesla.Adapter.Gun
    # set per module
    defmodule MyClient do
      use Tesla
      adapter Tesla.Adapter.Gun
    end
    ```

    ### Adapter specific options:

    * `timeout` - Time, while process, will wait for gun messages.
    * `body_as` - What will be returned in `%Tesla.Env{}` body key. Possible values - `:plain`, `:stream`, `:chunks`. Defaults to `:plain`.
        * `:plain` - as binary.
        * `:stream` - as stream. If you don't want to close connection (because you want to reuse it later) pass `close_conn: false` in adapter opts.
        * `:chunks` - as chunks. You can get response body in chunks using `Tesla.Adapter.Gun.read_chunk/3` function.

        Processing of the chunks and checking body size must be done by yourself. Example of processing function is in `test/tesla/adapter/gun_test.exs` - `read_body/3`. If you don't need connection later don't forget to close it with `Tesla.Adapter.Gun.close/1`.
    * `max_body` - Max response body size in bytes. Works only with `body_as: :plain`, with other settings you need to check response body size by yourself.
    * `conn` - Opened connection pid with gun. Is used for reusing gun connections.
    * `original` - Original host with port, for which reused connection was open. Needed for `Tesla.Middleware.FollowRedirects`. Otherwise adapter will use connection for another open host.
    * `close_conn` - Close connection or not after receiving full response body. Is used for reusing gun connections. Defaults to `true`.
    * `certificates_verification` - Add SSL certificates verification. [erlang-certifi](https://github.com/certifi/erlang-certifi) [ssl_verify_fun.erl](https://github.com/deadtrickster/ssl_verify_fun.erl)

    ### [Gun options](https://ninenines.eu/docs/en/gun/1.3/manual/gun/):

    * `connect_timeout` - Connection timeout.
    * `http_opts` - Options specific to the HTTP protocol.
    * `http2_opts` -  Options specific to the HTTP/2 protocol.
    * `protocols` - Ordered list of preferred protocols. Defaults: [http2, http] - for :tls, [http] - for :tcp.
    * `trace` - Whether to enable dbg tracing of the connection process. Should only be used during debugging. Default: false.
    * `transport` - Whether to use TLS or plain TCP. The default varies depending on the port used. Port 443 defaults to tls. All other ports default to tcp.
    * `transport_opts` - Transport options. They are TCP options or TLS options depending on the selected transport. Default: []. Gun version: 1.3
    * `tls_opts` - TLS transport options. Default: []. Gun from master branch.
    * `tcp_opts` - TCP trasnport options. Default: []. Gun from master branch.
    * `ws_opts` - Options specific to the Websocket protocol. Default: %{}.
        * `compress` - Whether to enable permessage-deflate compression. This does not guarantee that compression will be used as it is the server that ultimately decides. Defaults to false.
        * `protocols` - A non-empty list enables Websocket protocol negotiation. The list of protocols will be sent in the sec-websocket-protocol request header. The handler module interface is currently undocumented and must be set to `gun_ws_h`.

    """
    @behaviour Tesla.Adapter
    alias Tesla.Multipart

    @gun_keys [
      :connect_timeout,
      :http_opts,
      :http2_opts,
      :protocols,
      :retry,
      :retry_timeout,
      :trace,
      :transport,
      :ws_opts
    ]

    @adapter_default_timeout 1_000

    @impl true
    @doc false
    def call(env, opts) do
      with {:ok, status, headers, body} <- request(env, opts) do
        {:ok, %{env | status: status, headers: format_headers(headers), body: body}}
      end
    end

    defp format_headers(headers) do
      for {key, value} <- headers do
        {String.downcase(to_string(key)), to_string(value)}
      end
    end

    defp format_method(method), do: String.upcase(to_string(method))

    defp format_url(nil, nil), do: "/"
    defp format_url(nil, query), do: "/?" <> query
    defp format_url(path, nil), do: path
    defp format_url(path, query), do: path <> "?" <> query

    defp request(env, opts) do
      request(
        format_method(env.method),
        Tesla.build_url(env.url, env.query),
        env.headers,
        env.body || "",
        Tesla.Adapter.opts(
          [close_conn: true, body_as: :plain, send_body: :at_once, receive: true],
          env,
          opts
        )
        |> Enum.into(%{})
      )
    end

    defp request(method, url, headers, %Stream{} = body, opts),
      do: request_stream(method, url, headers, body, Map.put(opts, :send_body, :stream))

    defp request(method, url, headers, body, opts) when is_function(body),
      do: request_stream(method, url, headers, body, Map.put(opts, :send_body, :stream))

    defp request(method, url, headers, %Multipart{} = mp, opts) do
      headers = headers ++ Multipart.headers(mp)
      body = Multipart.body(mp)

      request(method, url, headers, body, opts)
    end

    defp request(method, url, headers, body, opts),
      do: do_request(method, url, headers, body, opts)

    defp request_stream(method, url, headers, body, opts),
      do: do_request(method, url, headers, body, opts)

    defp do_request(method, url, headers, body, opts) do
      with uri <- URI.parse(url),
           path_with_query <- format_url(uri.path, uri.query),
           {pid, opts} <- open_conn(uri, opts),
           stream <- open_stream(pid, method, path_with_query, headers, body, opts[:send_body]) do
        read_response(pid, stream, opts)
      end
    end

    defp open_conn(uri, %{conn: conn, original: original} = opts) do
      if original == "#{uri.host}:#{uri.port}" do
        {conn, Map.put(opts, :receive, false)}
      else
        # current url is different from the original, maybe there were redirects
        # so we can't use transferred connection
        open_conn(uri, Map.delete(opts, :conn))
      end
    end

    defp open_conn(uri, opts) do
      opts =
        if uri.scheme == "https" and uri.port != 443 do
          Map.put(opts, :transport, :tls)
        else
          opts
        end

      # We need to add `server_name_indication` option, because gun connects through ip in master branch.
      # [SNI] - http://erlang.org/doc/man/ssl.html#type-sni
      # Support for gun master branch where transport_opts, were splitted to tls_opts and tcp_opts
      # https://github.com/ninenines/gun/blob/491ddf58c0e14824a741852fdc522b390b306ae2/doc/src/manual/gun.asciidoc#changelog

      tls_opts =
        Map.get(opts, :tls_opts, [])
        |> Keyword.merge(Map.get(opts, :transport_opts, []))

      tls_opts =
        if uri.scheme == "https" do
          host = uri.host |> to_charlist()

          ssl_opts = [
            server_name_indication: host
          ]

          ssl_opts =
            if opts[:certificates_verification] do
              security_opts = [
                verify: :verify_peer,
                cacerts: :certifi.cacerts(),
                depth: 20,
                reuse_sessions: false,
                verify_fun: {&:ssl_verify_hostname.verify_fun/3, [check_hostname: host]}
              ]

              Keyword.merge(ssl_opts, security_opts)
            else
              ssl_opts
            end

          Keyword.merge(tls_opts, ssl_opts)
        else
          tls_opts
        end

      gun_opts = Map.take(opts, @gun_keys)

      with {:ok, pid} <- do_open_conn(uri, opts, gun_opts, tls_opts) do
        # If there were redirects, and passed `closed_conn: false`, we need to close opened connections to these intermediate hosts.
        {pid, Map.put(opts, :close_conn, true)}
      end
    end

    defp do_open_conn(uri, %{proxy: {proxy_host, proxy_port}}, gun_opts, tls_opts) do
      connect_opts = %{host: to_charlist(uri.host), port: uri.port}

      connect_opts =
        if uri.scheme == "https" do
          Map.put(connect_opts, :protocols, [:http2])
          |> Map.put(:transport, :tls)
          |> Map.put(:tls_opts, tls_opts)
        else
          connect_opts
        end

      with {:ok, pid} <- :gun.open(proxy_host, proxy_port, gun_opts),
           {:ok, _} <- :gun.await_up(pid),
           stream <- :gun.connect(pid, connect_opts),
           {:response, :fin, 200, _} <- :gun.await(pid, stream) do
        {:ok, pid}
      end
    end

    defp do_open_conn(uri, opts, gun_opts, tls_opts) do
      tcp_opts = Map.get(opts, :tcp_opts, [])

      # if gun used from master
      opts_with_master_keys =
        Map.put(gun_opts, :tls_opts, tls_opts)
        |> Map.put(:tcp_opts, tcp_opts)

      host = to_charlist(uri.host)

      with {:ok, pid} <- :gun.open(host, uri.port, opts_with_master_keys) do
        {:ok, pid}
      else
        {:error, {:options, {key, _}}} when key in [:tcp_opts, :tls_opts] ->
          :gun.open(
            host,
            uri.port,
            Map.put(gun_opts, :transport_opts, tls_opts)
          )
      end
    end

    defp open_stream(pid, method, url, headers, body, :stream) do
      stream = :gun.request(pid, method, url, headers, "")
      for data <- body, do: :ok = :gun.data(pid, stream, :nofin, data)
      :gun.data(pid, stream, :fin, "")
      stream
    end

    defp open_stream(pid, method, url, headers, body, :at_once),
      do: :gun.request(pid, method, url, headers, body)

    defp read_response(pid, stream, opts) do
      receive? = opts[:receive]

      receive do
        {:gun_response, ^pid, ^stream, :fin, status, headers} ->
          if opts[:close_conn], do: close(pid)
          {:ok, status, headers, ""}

        {:gun_response, ^pid, ^stream, :nofin, status, headers} ->
          format_response(pid, stream, opts, status, headers, opts[:body_as])

        {:error, error} ->
          if opts[:close_conn], do: close(pid)
          {:error, error}

        {:gun_up, ^pid, _protocol} when receive? ->
          read_response(pid, stream, opts)

        {:gun_error, ^pid, reason} ->
          if opts[:close_conn], do: close(pid)
          {:error, reason}

        {:gun_down, ^pid, _, _, _, _} when receive? ->
          read_response(pid, stream, opts)

        {:DOWN, _, _, _, reason} ->
          if opts[:close_conn], do: close(pid)
          {:error, reason}
      after
        opts[:timeout] || @adapter_default_timeout ->
          if opts[:close_conn], do: :ok = close(pid)
          {:error, :timeout}
      end
    end

    defp format_response(pid, stream, opts, status, headers, :plain) do
      case read_body(pid, stream, opts) do
        {:ok, body} ->
          if opts[:close_conn], do: close(pid)
          {:ok, status, headers, body}

        {:error, error} ->
          if opts[:close_conn], do: close(pid)
          {:error, error}
      end
    end

    defp format_response(pid, stream, opts, status, headers, :stream) do
      stream_body =
        Stream.resource(
          fn -> %{pid: pid, stream: stream} end,
          fn
            %{pid: pid, stream: stream} ->
              case read_chunk(pid, stream, opts) do
                {:nofin, part} -> {[part], %{pid: pid, stream: stream}}
                {:fin, body} -> {[body], %{pid: pid, final: :fin}}
              end

            %{pid: pid, final: :fin} ->
              {:halt, %{pid: pid}}
          end,
          fn %{pid: pid} ->
            if opts[:close_conn], do: close(pid)
          end
        )

      {:ok, status, headers, stream_body}
    end

    defp format_response(pid, stream, opts, status, headers, :chunks) do
      {:ok, status, headers, %{pid: pid, stream: stream, opts: Enum.into(opts, [])}}
    end

    @doc """
    Reads chunk of the response body.
    Returns `{:fin, binary()}` if all body received, otherwise returns `{:nofin, binary()}`.
    """
    @spec read_chunk(pid(), reference(), keyword() | map()) ::
            {:fin, binary()} | {:nofin, binary()} | {:error, :timeout}
    def read_chunk(pid, stream, opts) do
      receive do
        {:gun_data, ^pid, ^stream, :fin, body} ->
          {:fin, body}

        {:gun_data, ^pid, ^stream, :nofin, part} ->
          {:nofin, part}
      after
        opts[:timeout] || @adapter_default_timeout ->
          {:error, :timeout}
      end
    end

    @doc """
    Brutally close the `gun` connection
    """
    @spec close(pid()) :: :ok
    def close(pid) do
      :gun.close(pid)
    end

    defp read_body(pid, stream, opts, acc \\ "") do
      limit = opts[:max_body]

      receive do
        {:gun_data, ^pid, ^stream, :fin, body} ->
          check_body_size(acc, body, limit)

        {:gun_data, ^pid, ^stream, :nofin, part} ->
          case check_body_size(acc, part, limit) do
            {:ok, acc} -> read_body(pid, stream, opts, acc)
            {:error, error} -> {:error, error}
          end
      after
        opts[:timeout] || @adapter_default_timeout ->
          {:error, :timeout}
      end
    end

    defp check_body_size(acc, part, nil), do: {:ok, acc <> part}

    defp check_body_size(acc, part, limit) do
      body = acc <> part

      if limit - byte_size(body) >= 0 do
        {:ok, body}
      else
        {:error, :body_too_large}
      end
    end
  end
end
