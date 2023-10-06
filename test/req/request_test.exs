defmodule Req.RequestTest do
  use ExUnit.Case, async: true
  doctest Req.Request, except: [delete_header: 2]

  setup do
    bypass = Bypass.open()
    [bypass: bypass, url: "http://localhost:#{bypass.port}"]
  end

  test "low-level API", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request = new(url: c.url <> "/ok")
    assert {:ok, %{status: 200, body: "ok"}} = Req.Request.run(request)
  end

  test "merge_options/2: deprecated options" do
    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Req.Request.merge_options(Req.new(), url: "foo", headers: "bar")
      end)

    assert output =~ "Passing :url/:headers is deprecated"
  end

  test "simple request step", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      new(url: c.url <> "/not-found")
      |> Req.Request.prepend_request_steps(
        foo: fn request ->
          put_in(request.url.path, "/ok")
        end
      )

    assert {:ok, %{status: 200, body: "ok"}} = Req.Request.run(request)
  end

  test "request step returns response", c do
    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_request_steps(
        foo: fn request ->
          {request, %Req.Response{status: 200, body: "from cache"}}
        end
      )
      |> Req.Request.prepend_response_steps(
        foo: fn {request, response} ->
          {request, update_in(response.body, &(&1 <> " - updated"))}
        end
      )

    assert {:ok, %{status: 200, body: "from cache - updated"}} = Req.Request.run(request)
  end

  test "request steps emit telemtry events", c do
    ref = :telemetry_test.attach_event_handlers(self(), [[:req, :request_steps, :start], [:req, :request_steps, :stop]])

    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_request_steps(
        foo: fn request ->
          {request, %Req.Response{status: 200, body: "from cache"}}
        end
      )
      |> Req.Request.prepend_response_steps(
        foo: fn {request, response} ->
          {request, update_in(response.body, &(&1 <> " - updated"))}
        end
      )

    assert {:ok, %{status: 200, body: "from cache - updated"}} = Req.Request.run(request)

    assert_received {[:req, :request_steps, :start], ^ref, _timestamps, %{step: :foo}}
    assert_received {[:req, :request_steps, :stop], ^ref, %{ duration: duration}, meta}

    assert %{step: :foo, telemetry_span_context: _} = meta
    assert duration > 0
  end


  test "request step returns exception", c do
    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_request_steps(
        foo: fn request ->
          {request, RuntimeError.exception("oops")}
        end
      )
      |> Req.Request.prepend_error_steps(
        foo: fn {request, exception} ->
          {request, update_in(exception.message, &(&1 <> " - updated"))}
        end
      )

    assert {:error, %RuntimeError{message: "oops - updated"}} = Req.Request.run(request)
  end

  test "request step returns exception, emits error_steps telemtry", c do
    ref = :telemetry_test.attach_event_handlers(self(), [[:req, :error_steps, :start], [:req, :error_steps, :stop]])

    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_request_steps(
        foo: fn request ->
          {request, RuntimeError.exception("oops")}
        end
      )
      |> Req.Request.prepend_error_steps(
        foo_error: fn {request, exception} ->
          {request, update_in(exception.message, &(&1 <> " - updated"))}
        end
      )

    assert {:error, %RuntimeError{message: "oops - updated"}} = Req.Request.run(request)
    assert_received {[:req, :error_steps, :start], ^ref, _timestamps, %{step: :foo_error}}
    assert_received {[:req, :error_steps, :stop], ^ref, %{ duration: _duration}, meta}
    assert %{step: :foo_error, telemetry_span_context: _} = meta
  end

  test "request step halts with response", c do
    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_request_steps(
        foo: fn request ->
          {Req.Request.halt(request), %Req.Response{status: 200, body: "from cache"}}
        end,
        bar: &unreachable/1
      )
      |> Req.Request.prepend_response_steps(foo: &unreachable/1)
      |> Req.Request.prepend_error_steps(foo: &unreachable/1)

    assert {:ok, %{status: 200, body: "from cache"}} = Req.Request.run(request)
  end

  test "request step halts with exception", c do
    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_request_steps(
        foo: fn request ->
          {Req.Request.halt(request), RuntimeError.exception("oops")}
        end,
        bar: &unreachable/1
      )
      |> Req.Request.prepend_response_steps(foo: &unreachable/1)
      |> Req.Request.prepend_error_steps(foo: &unreachable/1)

    assert {:error, %RuntimeError{message: "oops"}} = Req.Request.run(request)
  end

  test "simple response step", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_response_steps(
        foo: fn {request, response} ->
          {request, update_in(response.body, &(&1 <> " - updated"))}
        end
      )

    assert {:ok, %{status: 200, body: "ok - updated"}} = Req.Request.run(request)
  end

  test "response steps emit telemtry", c do
    ref = :telemetry_test.attach_event_handlers(self(), [[:req, :response_steps, :start], [:req, :response_steps, :stop]])

    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_response_steps(
        foo: fn {request, response} ->
          {request, update_in(response.body, &(&1 <> " - updated"))}
        end,
        bar: fn {request, response} ->
          {request, update_in(response.body, &(&1 <> " - bar-red"))}
        end
      )

    assert {:ok, %{status: 200, body: "ok - updated - bar-red"}} = Req.Request.run(request)

    assert_received {[:req, :response_steps, :start], ^ref, _timestamps, %{step: :foo}}
    assert_received {[:req, :response_steps, :stop], ^ref, %{duration: _duration}, meta}
    assert %{step: :foo, telemetry_span_context: _} = meta

    assert_received {[:req, :response_steps, :start], ^ref, _timestamps, %{step: :bar}}
    assert_received {[:req, :response_steps, :stop], ^ref, %{duration: _duration}, meta}
    assert %{step: :bar, telemetry_span_context: _} = meta
  end

  test "response step returns exception", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_response_steps(
        foo: fn {request, response} ->
          assert response.body == "ok"
          {request, RuntimeError.exception("oops")}
        end
      )
      |> Req.Request.prepend_error_steps(
        foo: fn {request, exception} ->
          {request, update_in(exception.message, &(&1 <> " - updated"))}
        end
      )

    assert {:error, %RuntimeError{message: "oops - updated"}} = Req.Request.run(request)
  end

  test "response step halts with response", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_response_steps(
        foo: fn {request, response} ->
          {Req.Request.halt(request), update_in(response.body, &(&1 <> " - updated"))}
        end,
        bar: &unreachable/1
      )
      |> Req.Request.prepend_error_steps(foo: &unreachable/1)

    assert {:ok, %{status: 200, body: "ok - updated"}} = Req.Request.run(request)
  end

  test "response step halts with exception", c do
    Bypass.expect(c.bypass, "GET", "/ok", fn conn ->
      Plug.Conn.send_resp(conn, 200, "ok")
    end)

    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_response_steps(
        foo: fn {request, response} ->
          assert response.body == "ok"
          {Req.Request.halt(request), RuntimeError.exception("oops")}
        end,
        bar: &unreachable/1
      )
      |> Req.Request.prepend_error_steps(foo: &unreachable/1)

    assert {:error, %RuntimeError{message: "oops"}} = Req.Request.run(request)
  end

  test "simple error step", c do
    Bypass.down(c.bypass)

    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_error_steps(
        foo: fn {request, exception} ->
          assert exception.reason == :econnrefused
          {request, RuntimeError.exception("oops")}
        end
      )

    assert {:error, %RuntimeError{message: "oops"}} = Req.Request.run(request)
  end

  test "error step returns response", c do
    Bypass.down(c.bypass)

    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_response_steps(
        foo: fn {request, response} ->
          {request, update_in(response.body, &(&1 <> " - updated"))}
        end
      )
      |> Req.Request.prepend_error_steps(
        foo: fn {request, exception} ->
          assert exception.reason == :econnrefused
          {request, %Req.Response{status: 200, body: "ok"}}
        end,
        bar: &unreachable/1
      )

    assert {:ok, %{status: 200, body: "ok - updated"}} = Req.Request.run(request)
  end

  test "error step halts with response", c do
    Bypass.down(c.bypass)

    request =
      new(url: c.url <> "/ok")
      |> Req.Request.prepend_response_steps(foo: &unreachable/1)
      |> Req.Request.prepend_error_steps(
        foo: fn {request, exception} ->
          assert exception.reason == :econnrefused
          {Req.Request.halt(request), %Req.Response{status: 200, body: "ok"}}
        end,
        bar: &unreachable/1
      )

    assert {:ok, %{status: 200, body: "ok"}} = Req.Request.run(request)
  end

  test "prepare/1" do
    request =
      Req.new(method: :get, base_url: "http://foo", url: "/bar", auth: {"foo", "bar"})
      |> Req.Request.prepare()

    assert request.url == URI.parse("http://foo/bar")

    authorization = "Basic " <> Base.encode64("foo:bar")

    if Req.MixProject.legacy_headers_as_lists?() do
      assert [
               {"user-agent", "req/0.3.11"},
               {"accept-encoding", "zstd, br, gzip"},
               {"authorization", ^authorization}
             ] = request.headers
    else
      assert %{
               "user-agent" => ["req/" <> _],
               "accept-encoding" => ["zstd, br, gzip"],
               "authorization" => [^authorization]
             } = request.headers
    end
  end

  test "prepare/1 also emits telemtry" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:req, :prepare_steps, :start], [:req, :prepare_steps, :stop]])

    request =
      Req.new(method: :get, base_url: "http://foo", url: "/bar", auth: {"foo", "bar"})
      |> Req.Request.prepare()

    assert request.url == URI.parse("http://foo/bar")

    authorization = "Basic " <> Base.encode64("foo:bar")

    if Req.MixProject.legacy_headers_as_lists?() do
      assert [
               {"user-agent", "req/0.3.11"},
               {"accept-encoding", "zstd, br, gzip"},
               {"authorization", ^authorization}
             ] = request.headers
    else
      assert %{
               "user-agent" => ["req/" <> _],
               "accept-encoding" => ["zstd, br, gzip"],
               "authorization" => [^authorization]
             } = request.headers
    end

    assert_received {[:req, :prepare_steps, :start], ^ref, _timestamps, _meta}
    assert_received {[:req, :prepare_steps, :stop], ^ref, %{duration: _duration}, meta}
    assert %{step: _prepare_step_name, telemetry_span_context: _} = meta
  end

  ## Helpers

  defp new(options) do
    options = Keyword.update(options, :url, nil, &URI.parse/1)
    struct!(Req.Request, options)
  end

  defp unreachable(_) do
    raise "unreachable"
  end
end
