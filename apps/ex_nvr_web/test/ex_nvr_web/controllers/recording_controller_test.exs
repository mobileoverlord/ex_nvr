defmodule ExNVRWeb.RecordingControllerTest do
  use ExNVRWeb.ConnCase

  alias Faker.Random

  setup_all do
    on_exit(fn -> clean_recording_directory() end)
  end

  describe "GET /api/devices/:device_id/recordings/:recording_id/blob" do
    setup do
      device = create_device!()
      %{device: device}
    end

    test "get recording blob", %{device: device} do
      content = Random.Elixir.random_bytes(20)
      file_path = create_temp_file!(content)
      recording = create_recording!(device_id: device.id, path: file_path)

      response =
        build_conn()
        |> get("/api/devices/#{device.id}/recordings/#{recording.filename}/blob")
        |> response(200)

      assert response == content

      File.rm!(file_path)
    end

    test "get blob of not existing recording", %{device: device} do
      build_conn()
      |> get("/api/devices/#{device.id}/recordings/#{UUID.uuid4()}/blob")
      |> response(404)
    end
  end
end
