defmodule ExNvr.Elements.SegmenterPipelineTest do
  use ExUnit.Case

  require Membrane.Pad

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  alias ExNVR.Elements.Segmenter
  alias Membrane.{Buffer, H264, Realtimer}
  alias Membrane.Testing.{Pipeline, Sink, Source}

  @buffer_payload <<0::size(10)-unit(8)>>

  test "segment buffers" do
    times = [0, 400, 800, 1200, 1600, 2000, 2400, 2800]
    key_frames? = [true, false, false, false, true, false, false, false]

    pid =
      Enum.zip(times, key_frames?)
      |> Enum.map(fn {time, key_frame?} -> create_buffer(time, key_frame?) end)
      |> Source.output_from_buffers()
      |> start_pipeline()

    Pipeline.execute_actions(pid, playback: :playing)

    Enum.each(0..1, fn i ->
      assert_pipeline_notified(pid, :segmenter, {:new_media_segment, ref})

      Pipeline.execute_actions(pid,
        spec: [
          get_child(:segmenter)
          |> via_out(Membrane.Pad.ref(:output, ref))
          |> child({:sink, ref}, Sink)
        ]
      )

      Enum.each(0..3, fn _ ->
        assert_sink_buffer(pid, {:sink, ref}, %Buffer{payload: @buffer_payload})
      end)

      end_run? = i == 1
      assert_pipeline_notified(pid, :segmenter, {:completed_segment, {^ref, _, ^end_run?}})
      assert_end_of_stream(pid, {:sink, ^ref})
    end)

    Pipeline.terminate(pid)
  end

  defp create_buffer(pts, key_frame?) do
    %Buffer{
      payload: @buffer_payload,
      pts: Membrane.Time.milliseconds(pts),
      metadata: %{h264: %{key_frame?: key_frame?}}
    }
  end

  defp start_pipeline(data) do
    structure = [
      child(:source, %Source{
        output: data,
        stream_format: %H264{
          width: nil,
          height: nil,
          framerate: nil,
          alignment: :au,
          nalu_in_metadata?: nil,
          profile: nil
        }
      })
      # The realtimer is needed to avoid buffering the whole input
      # and send them all once the output pad of segmenter is linked
      # This will make the tests slower, a new approach is needed
      |> child(:realtimer, Realtimer)
      |> child(:segmenter, %Segmenter{segment_duration: 1})
    ]

    Pipeline.start_link_supervised!(structure: structure)
  end
end
