// The few calls from Windows' device list (cfgmgr32.h) USB needs. That header itself can't be
// used: it re-declares types Swift's WinSDK module already has (devpropdef.h). Empty elsewhere.
#ifdef _WIN32
#include <windows.h>

typedef DWORD NSCONFIGRET; // CONFIGRET: CR_SUCCESS (0), CR_BUFFER_SMALL (0x1A), ...
typedef DWORD NSDEVINST;   // DEVINST
typedef struct { GUID fmtid; ULONG pid; } NSDEVPROPKEY; // DEVPROPKEY

__declspec(dllimport) NSCONFIGRET WINAPI CM_Get_Device_Interface_List_SizeW(PULONG length, LPGUID interfaceClass, PWSTR deviceID, ULONG flags);
__declspec(dllimport) NSCONFIGRET WINAPI CM_Get_Device_Interface_ListW(LPGUID interfaceClass, PWSTR deviceID, PZZWSTR buffer, ULONG length, ULONG flags);
__declspec(dllimport) NSCONFIGRET WINAPI CM_Get_Device_Interface_PropertyW(LPCWSTR deviceInterface, const NSDEVPROPKEY *key, ULONG *type, PBYTE buffer, PULONG size, ULONG flags);
__declspec(dllimport) NSCONFIGRET WINAPI CM_Locate_DevNodeW(NSDEVINST *node, PWSTR deviceID, ULONG flags);
__declspec(dllimport) NSCONFIGRET WINAPI CM_Get_Parent(NSDEVINST *parent, NSDEVINST node, ULONG flags);
__declspec(dllimport) NSCONFIGRET WINAPI CM_Get_Device_IDW(NSDEVINST node, PWSTR buffer, ULONG length, ULONG flags);
__declspec(dllimport) NSCONFIGRET WINAPI CM_Get_DevNode_PropertyW(NSDEVINST node, const NSDEVPROPKEY *key, ULONG *type, PBYTE buffer, PULONG size, ULONG flags);
#endif
