defmodule Bandit.HTTP2.Handler do
  @moduledoc """
  An HTTP/2 handler. Responsible for:

  * Coordinating the parsing of frames & attendant error handling
  * Tracking connection state as represented by `Bandit.HTTP2.Connection` structs
  * Marshalling send requests from child streams into the parent connection for processing
  """

  use ThousandIsland.Handler

  alias Bandit.HTTP2.{Connection, Errors, Frame}

  @impl ThousandIsland.Handler
  def handle_connection(socket, state) do
    case Connection.init(socket, state.plug, state.read_timeout) do
      {:ok, connection} ->
        {:ok, :continue, state |> Map.merge(%{buffer: <<>>, connection: connection}),
         state.read_timeout}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  @impl ThousandIsland.Handler
  def handle_data(data, socket, state) do
    (state.buffer <> data)
    |> Stream.unfold(&Frame.deserialize(&1, state.connection.local_settings.max_frame_size))
    |> Enum.reduce_while({:ok, :continue, state, state.read_timeout}, fn
      {:ok, frame}, {:ok, :continue, state, _timeout} ->
        case Connection.handle_frame(frame, socket, state.connection) do
          {:ok, :continue, connection} ->
            {:cont,
             {:ok, :continue, %{state | connection: connection, buffer: <<>>}, state.read_timeout}}

          {:ok, :close, connection} ->
            {:halt, {:ok, :close, %{state | connection: connection, buffer: <<>>}}}

          {:error, reason, connection} ->
            {:halt, {:error, reason, %{state | connection: connection, buffer: <<>>}}}
        end

      {:more, rest}, {:ok, :continue, state, _timeout} ->
        {:halt, {:ok, :continue, %{state | buffer: rest}, state.read_timeout}}

      {:error, {:connection, code, reason}}, {:ok, :continue, state, _timeout} ->
        # We encountered an error while deserializing the frame. Let the connection figure out
        # how to respond to it
        case Connection.shutdown_connection(code, reason, socket, state.connection) do
          {:error, reason, connection} ->
            {:halt, {:error, reason, %{state | connection: connection, buffer: <<>>}}}
        end
    end)
  end

  @impl ThousandIsland.Handler
  def handle_shutdown(socket, state) do
    Connection.shutdown_connection(Errors.no_error(), "Server shutdown", socket, state.connection)
  end

  @impl ThousandIsland.Handler
  def handle_timeout(socket, state) do
    Connection.shutdown_connection(Errors.no_error(), "Client timeout", socket, state.connection)
  end

  def handle_call({:send_headers, stream_id, headers, end_stream}, {pid, _tag}, {socket, state}) do
    case Connection.send_headers(stream_id, pid, headers, end_stream, socket, state.connection) do
      {:ok, connection} ->
        {:reply, :ok, {socket, %{state | connection: connection}}, state.read_timeout}

      {:error, reason} ->
        {:reply, {:error, reason}, {socket, state}, state.read_timeout}
    end
  end

  def handle_call({:send_data, stream_id, data, end_stream}, {pid, _tag} = from, {socket, state}) do
    # It's possible that this send could not complete syncronously if we do not have enough space
    # in either/both our connection or stream send windows. In this case Connection.send_data will
    # return false as the second value of its result tuple, signaling that we should `:no_reply`
    # to the caller. If/when the send window(s) are enlarged by the client and the data in the
    # data from this call is sent successfully, the unblock function will be called & our caller
    # process will be replied to. This ensures that we have backpressure all the way back to the
    # stream's handler process in the event of window overruns
    unblock = fn -> GenServer.reply(from, :ok) end

    case Connection.send_data(stream_id, pid, data, end_stream, unblock, socket, state.connection) do
      {:ok, true, connection} ->
        {:reply, :ok, {socket, %{state | connection: connection}}, state.read_timeout}

      {:ok, false, connection} ->
        {:noreply, {socket, %{state | connection: connection}}, state.read_timeout}

      {:error, reason} ->
        {:reply, {:error, reason}, {socket, state}, state.read_timeout}
    end
  end

  def handle_call({:send_push, stream_id, headers}, _from, {socket, state}) do
    case Connection.send_push(stream_id, headers, socket, state.connection) do
      {:ok, connection} ->
        {:reply, :ok, {socket, %{state | connection: connection}}, state.read_timeout}

      {:error, reason} ->
        {:reply, {:error, reason}, {socket, state}, state.read_timeout}
    end
  end

  def handle_info({:EXIT, pid, reason}, {socket, state}) do
    case Connection.stream_terminated(pid, reason, socket, state.connection) do
      {:ok, connection} ->
        {:noreply, {socket, %{state | connection: connection}}, state.read_timeout}

      {:error, _error} ->
        {:noreply, {socket, state}, state.read_timeout}
    end
  end
end
