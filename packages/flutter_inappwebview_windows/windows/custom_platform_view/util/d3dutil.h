#pragma once

#include <D3d11.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.System.h>

inline auto CreateD3DDevice(D3D_DRIVER_TYPE const type,
                            UINT const flags,
                            winrt::com_ptr<ID3D11Device>& device) {
  WINRT_ASSERT(!device);

  return D3D11CreateDevice(nullptr, type, nullptr, flags, nullptr, 0,
                           D3D11_SDK_VERSION, device.put(), nullptr, nullptr);
}

inline auto CreateD3DDevice() {
  winrt::com_ptr<ID3D11Device> device;
  // 1. Try Hardware with BGRA + VIDEO_SUPPORT
  HRESULT hr = CreateD3DDevice(
      D3D_DRIVER_TYPE_HARDWARE,
      D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
      device);

  // 2. Windows N/KN & older Intel HD / AMD GPUs reject VIDEO_SUPPORT with E_INVALIDARG (0x80070057)
  if (FAILED(hr) || !device) {
    device = nullptr;
    hr = CreateD3DDevice(
        D3D_DRIVER_TYPE_HARDWARE,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        device);
  }

  // 3. Fallback to software WARP rasterizer if hardware D3D11 is unavailable/broken
  if (FAILED(hr) || !device) {
    device = nullptr;
    CreateD3DDevice(
        D3D_DRIVER_TYPE_WARP,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT,
        device);
  }

  return device;
}
