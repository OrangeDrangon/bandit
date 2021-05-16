defmodule HTTP2FrameSerializationTest do
  use ExUnit.Case, async: true

  alias Bandit.HTTP2.Frame

  describe "SETTINGS frames" do
    test "serializes non-ack frames when there are no contained settings" do
      frame = %Frame.Settings{ack: false, settings: %{}}

      assert Frame.serialize(frame) == [<<0, 0, 0, 4, 0, 0, 0, 0, 0>>, <<>>]
    end

    test "serializes non-ack frames when there are contained settings" do
      frame = %Frame.Settings{ack: false, settings: %{1 => 2, 100 => 200}}

      assert Frame.serialize(frame) ==
               [<<0, 0, 12, 4, 0, 0, 0, 0, 0>>, <<0, 1, 0, 0, 0, 2, 0, 100, 0, 0, 0, 200>>]
    end

    test "serializes ack frames" do
      frame = %Frame.Settings{ack: true, settings: %{}}

      assert Frame.serialize(frame) == [<<0, 0, 0, 4, 1, 0, 0, 0, 0>>, <<>>]
    end
  end

  describe "PING frames" do
    test "serializes non-ack frames" do
      frame = %Frame.Ping{ack: false, payload: <<1, 2, 3, 4, 5, 6, 7, 8>>}

      assert Frame.serialize(frame) == [<<0, 0, 8, 6, 0, 0, 0, 0, 0>>, <<1, 2, 3, 4, 5, 6, 7, 8>>]
    end

    test "serializes ack frames" do
      frame = %Frame.Ping{ack: true, payload: <<1, 2, 3, 4, 5, 6, 7, 8>>}

      assert Frame.serialize(frame) == [<<0, 0, 8, 6, 1, 0, 0, 0, 0>>, <<1, 2, 3, 4, 5, 6, 7, 8>>]
    end
  end

  describe "GOAWAY frames" do
    test "serializes frames without debug data" do
      frame = %Frame.Goaway{last_stream_id: 1, error_code: 2}

      assert Frame.serialize(frame) == [<<0, 0, 8, 7, 0, 0, 0, 0, 0>>, <<0, 0, 0, 1, 0, 0, 0, 2>>]
    end

    test "serializes frames with debug data" do
      frame = %Frame.Goaway{last_stream_id: 1, error_code: 2, debug_data: <<3, 4>>}

      assert Frame.serialize(frame) ==
               [<<0, 0, 10, 7, 0, 0, 0, 0, 0>>, <<0, 0, 0, 1, 0, 0, 0, 2, 3, 4>>]
    end
  end
end
