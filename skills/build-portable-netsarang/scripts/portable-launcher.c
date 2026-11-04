/* Native GUI launcher for the no-admin portable NetSarang package.
 * It replaces the .cmd/.vbs entry points. The verified PowerShell bootstrap
 * (portable.ps1) still performs registry seeding, native runner launch and
 * settings persistence; this executable only starts it without a console
 * window, without cmd.exe and without Windows Script Host.
 * Vendor binaries are never modified. x86 / GUI subsystem. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>
#include <stdio.h>

static void fail(const wchar_t *message, DWORD error) {
    wchar_t text[1024];
    if (error) swprintf(text, L"%s\n\nWin32 error: %lu", message, error);
    else wcscpy(text, message);
    MessageBoxW(NULL, text, L"NetSarang Portable", MB_ICONERROR | MB_SETFOREGROUND);
}

static int prefixCI(const wchar_t *text, const wchar_t *prefix) {
    while (*prefix) {
        wchar_t a = *prefix++, b = *text++;
        if (a >= L'A' && a <= L'Z') a = (wchar_t)(a + 32);
        if (b >= L'A' && b <= L'Z') b = (wchar_t)(b + 32);
        if (!b || a != b) return 0;
    }
    return 1;
}

int WINAPI WinMain(HINSTANCE instance, HINSTANCE previous, LPSTR commandLine, int show) {
    wchar_t self[MAX_PATH], root[MAX_PATH], script[MAX_PATH], powershell[MAX_PATH], command[2048];
    wchar_t *slash, *filename;
    const wchar_t *app;
    STARTUPINFOW startup;
    PROCESS_INFORMATION pi;
    DWORD code = 1;

    if (!GetModuleFileNameW(NULL, self, MAX_PATH)) { fail(L"Cannot resolve the launcher path.", GetLastError()); return 1; }
    slash = wcsrchr(self, L'\\');
    if (!slash) { fail(L"Invalid launcher path.", 0); return 1; }
    filename = slash + 1;
    /* The same binary is delivered under two names; the name selects the app. */
    app = prefixCI(filename, L"xftp") ? L"Xftp" : L"Xshell";

    wcscpy(root, self);
    *wcsrchr(root, L'\\') = 0;
    swprintf(script, L"%s\\portable.ps1", root);
    if (GetFileAttributesW(script) == INVALID_FILE_ATTRIBUTES) {
        fail(L"portable.ps1 was not found beside this launcher. Extract the whole ZIP first.", 0);
        return 1;
    }
    if (!GetWindowsDirectoryW(powershell, MAX_PATH)) { fail(L"Cannot resolve the Windows directory.", GetLastError()); return 1; }
    wcscat(powershell, L"\\system32\\WindowsPowerShell\\v1.0\\powershell.exe");
    if (GetFileAttributesW(powershell) == INVALID_FILE_ATTRIBUTES) {
        fail(L"Windows PowerShell 5.1 was not found. This package requires it.", 0);
        return 1;
    }
    swprintf(command,
        L"\"%s\" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%s\" -App %s",
        powershell, script, app);

    ZeroMemory(&startup, sizeof(startup));
    ZeroMemory(&pi, sizeof(pi));
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    if (!CreateProcessW(NULL, command, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, root, &startup, &pi)) {
        fail(L"Could not start the portable bootstrap.", GetLastError());
        return 1;
    }
    CloseHandle(pi.hThread);
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    return (int)code;
}
