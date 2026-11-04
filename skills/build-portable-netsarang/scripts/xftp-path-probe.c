/* Verifies that, inside a bridge-injected x86 process, the vendor registry
 * lookups Xshell uses to locate Xftp resolve to THIS portable package.
 * Run via Tools/registry-runner.exe from the package's Tools directory so the
 * package root can be derived from the probe's own path. Self-checking: exits
 * non-zero on any mismatch. Vendor binaries are not modified. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <wchar.h>
#define CP_UTF8 65001
WINBASEAPI int WINAPI WideCharToMultiByte(UINT,DWORD,LPCWSTR,int,LPSTR,int,LPCSTR,LPBOOL);

static int errors;
static wchar_t root[MAX_PATH];

static int readString(const char *label, HKEY base, const wchar_t *sub, const wchar_t *name, wchar_t *out, DWORD capacity) {
    HKEY key;
    DWORD size = capacity * sizeof(wchar_t), type = 0;
    LONG status = RegOpenKeyExW(base, sub, 0, KEY_READ, &key);
    if (status != ERROR_SUCCESS) { printf("FAIL %s: RegOpenKeyExW=%ld\n", label, (long)status); return 0; }
    status = RegQueryValueExW(key, name, NULL, &type, (LPBYTE)out, &size);
    RegCloseKey(key);
    if (status != ERROR_SUCCESS || type != REG_SZ) { printf("FAIL %s: RegQueryValueExW=%ld type=%lu\n", label, (long)status, (unsigned long)type); return 0; }
    out[size / sizeof(wchar_t) ? size / sizeof(wchar_t) - 1 : 0] = 0;
    return 1;
}

static void check(const char *label, HKEY base, const wchar_t *sub, const wchar_t *name, const wchar_t *expected) {
    wchar_t value[1024];
    char utf8[2048];
    if (!readString(label, base, sub, name, value, 1024)) { errors++; return; }
    if (_wcsicmp(value, expected)) {
        WideCharToMultiByte(CP_UTF8, 0, value, -1, utf8, sizeof(utf8), NULL, NULL);
        printf("FAIL %s: unexpected value %s\n", label, utf8);
        errors++;
    } else {
        printf("PASS %s\n", label);
    }
}

int main(void) {
    wchar_t self[MAX_PATH], expected[1024], *slash;
    if (!GetModuleFileNameW(NULL, self, MAX_PATH)) return 2;
    slash = wcsrchr(self, L'\\'); if (!slash) return 3;
    *slash = 0;                                  /* strip executable name -> Tools */
    slash = wcsrchr(self, L'\\'); if (!slash) return 3;
    *slash = 0;                                  /* strip Tools -> package root */
    wcscpy(root, self);

    swprintf(expected, L"%s\\App\\Xftp 8", root);
    check("HKLM Xftp 8 Path", HKEY_LOCAL_MACHINE, L"SOFTWARE\\WOW6432Node\\NetSarang\\Xftp\\8", L"Path", expected);
    swprintf(expected, L"%s\\App\\Xshell 8", root);
    check("HKLM Xshell 8 Path", HKEY_LOCAL_MACHINE, L"SOFTWARE\\WOW6432Node\\NetSarang\\Xshell\\8", L"Path", expected);
    swprintf(expected, L"%s\\Data\\8", root);
    check("HKCU UserDataPath", HKEY_CURRENT_USER, L"Software\\NetSarang\\Common\\8\\UserData", L"UserDataPath", expected);

    if (errors) { printf("FAIL: %d portable path check(s)\n", errors); return 1; }
    printf("PASS: Xshell's Xftp lookup and user-data path both resolve inside this package\n");
    return 0;
}
