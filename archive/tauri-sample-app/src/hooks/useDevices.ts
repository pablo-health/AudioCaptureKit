import { useCallback, useEffect, useState } from "react";
import { commands, DeviceInfo } from "../lib/tauri";

export function useDevices() {
  const [captureDevices, setCaptureDevices] = useState<DeviceInfo[]>([]);
  const [renderDevices, setRenderDevices] = useState<DeviceInfo[]>([]);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      const [capture, render] = await Promise.all([
        commands.listCaptureDevices(),
        commands.listRenderDevices(),
      ]);
      setCaptureDevices(capture);
      setRenderDevices(render);
    } catch {
      // device enumeration may fail if no devices
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  return { captureDevices, renderDevices, loading, refresh };
}
