defmodule AwsExRay.Plug do

  @moduledoc ~S"""

  ## USAGE

  In your router, set `AwsExRay.Plug`.

  ```elixir
  defmodule MyPlugRouter do

    use Plug.Router

    plug AwsExRay.Plug, name: "my-xray", skip: [{:get, "/bar"}]

    plug :match
    plug :dispatch

    get "/foo" do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Poison.encode!(%{body: "Hello, Foo"}))
    end

    get "/bar" do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Poison.encode!(%{body: "Hello, Bar"}))
    end

  end
  ```

  When new http request comes, and it's **METHOD** and **PATH** pair is not included `:skip` option,
  Tracing is automatically started with the name which you passed with `:name` option.

  If the incoming request has valid **X-Amzn-Trace-Id** header,
  it tries to take over parent **Trace**, or else, it starts a new **Trace**.


  """

  import Plug.Conn

  alias AwsExRay.Plug.Paths
  alias AwsExRay.Record.Error
  alias AwsExRay.Record.Error.Cause
  alias AwsExRay.Record.HTTPRequest
  alias AwsExRay.Record.HTTPResponse
  alias AwsExRay.Segment
  alias AwsExRay.Stacktrace
  alias AwsExRay.Trace

  @type http_method :: :get | :post | :put | :delete

  @type t :: %__MODULE__{
    name: String.t,
    skip: [{http_method, String.t}]
  }

  defstruct name: "", skip: []

  def init(opts \\ []) do

    name = Keyword.fetch!(opts, :name)
    skip = Keyword.get(opts, :skip, [])

    %__MODULE__{
      name: name,
      skip: skip
    }

  end

  def call(conn, opts) do

    if can_skip_tracing(conn, opts) do

      conn

    else

      trace = get_trace(conn)

      {addr, forwarded} = find_client_ip(conn)

      url = conn
            |> request_url()
            |> String.split("?")
            |> List.first

      request_record = %HTTPRequest{
        segment_type:    :segment,
        method:          conn.method,
        url:             url,
        user_agent:      get_user_agent(conn),
        client_ip:       addr,
        x_forwarded_for: forwarded
      }

      segment = AwsExRay.start_tracing(trace, opts.name)
              |> Segment.set_http_request(request_record)

      register_before_send(conn, fn conn ->

        status = conn.status

        content_length = get_response_content_length(conn)

        response_record =
          HTTPResponse.new(status, content_length)

        segment =
          Segment.set_http_response(segment, response_record)

        segment =
          if status >= 400 && status < 600 do
            put_response_error(segment,
                               status,
                               Stacktrace.stacktrace())
          else
            segment
          end

        AwsExRay.finish_tracing(segment)

        conn

      end)

    end

  end

  defp find_client_ip(conn) do
    case get_req_header(conn, "x-real-ip") do

      [] ->
        case get_req_header(conn, "x-forwarded-for") do

          [] ->
            case get_req_header(conn, "remote_addr") do

              [] ->
                addr = "#{:inet.ntoa(conn.remote_ip)}"
                {addr, false}

              [value|_] -> {value, false}

            end

          [value|_] ->
            addr = value |> String.split(",") |> List.first |> String.trim
            {addr, true}
        end

      [value|_] -> {value, true}
    end
  end

  defp put_response_error(seg, status, stack) do
    case status do

      code when code == 429 ->

        cause = Cause.new(:http_response_error, "Got 429", stack)
        error = %Error{
          cause:    cause,
          throttle: true,
          error:    true,
          fault:    false,
          remote:   false,
        }
        Segment.set_error(seg, error)

      code when code >= 400 and code < 500 ->
        cause = Cause.new(:http_response_error, "Got 4xx", stack)
        error = %Error{
          cause:    cause,
          throttle: false,
          error:    true,
          fault:    false,
          remote:   false,
        }
        Segment.set_error(seg, error)

      code when code >= 500 and code < 600 ->
        cause = Cause.new(:http_response_error, "Got 5xx", stack)
        error = %Error{
          cause:    cause,
          throttle: false,
          error:    false,
          fault:    true,
          remote:   false,
        }
        Segment.set_error(seg, error)

      _ ->
        seg

    end
  end

  defp get_user_agent(conn) do
    case get_req_header(conn, "user-agent") do
      []        -> nil
      [value|_] -> value
    end
  end

  defp get_response_content_length(conn) do
    if is_binary(conn.resp_body) do
      byte_size(conn.resp_body)
    else
      :erlang.iolist_size(conn.resp_body)
    end
    #case get_resp_header(conn, "content-length") do
    #  []        -> 0
    #  [value|_] -> String.to_integer(value)
    #end
  end

  defp can_skip_tracing(conn, opts) do
    Paths.include(opts.skip, conn)
  end

  defp get_trace(conn) do
    with {:ok, value} <- find_trace_header(conn),
         {:ok, trace} <- Trace.parse(value) do
      trace
    else
      {:error, :not_found} -> Trace.new()
    end
  end

  defp find_trace_header(conn) do
    case get_req_header(conn, "x-amzn-trace-id") do
      []        -> {:error, :not_found}
      [value|_] -> {:ok, value}
    end
  end

end
