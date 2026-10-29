/* x86 process-local registry routing. Vendor executables remain unchanged. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wchar.h>
#include <stdio.h>
#include <string.h>
typedef LONG LSTATUS;
#define CP_UTF8 65001
#define CP_ACP 0
#define LOAD_LIBRARY_AS_IMAGE_RESOURCE 0x20
WINBASEAPI int WINAPI MultiByteToWideChar(UINT,DWORD,LPCSTR,int,LPWSTR,int);
#define TH32CS_SNAPMODULE 0x8
typedef struct { DWORD dwSize,th32ModuleID,th32ProcessID,GlblcntUsage,ProccntUsage; BYTE *modBaseAddr; DWORD modBaseSize; HMODULE hModule; WCHAR szModule[256],szExePath[MAX_PATH]; } MODULEENTRY32W;
WINBASEAPI HANDLE WINAPI CreateToolhelp32Snapshot(DWORD,DWORD);

static wchar_t bridge[MAX_PATH];
static int inject(HANDLE process, const wchar_t *dll) {
    SIZE_T size=(wcslen(dll)+1)*sizeof(wchar_t), written;
    void *remote=VirtualAllocEx(process,NULL,size,MEM_COMMIT|MEM_RESERVE,PAGE_READWRITE);
    HANDLE thread;
    DWORD result=0;
    if (!remote) return 1;
    if (!WriteProcessMemory(process,remote,dll,size,&written) || written!=size) { VirtualFreeEx(process,remote,0,MEM_RELEASE); return 2; }
    thread=CreateRemoteThread(process,NULL,0,(LPTHREAD_START_ROUTINE)GetProcAddress(GetModuleHandleW(L"kernel32.dll"),"LoadLibraryW"),remote,0,NULL);
    if (!thread) { VirtualFreeEx(process,remote,0,MEM_RELEASE); return 3; }
    if (WaitForSingleObject(thread,30000)!=WAIT_OBJECT_0) { CloseHandle(thread); return 4; }
    GetExitCodeThread(thread,&result);
    CloseHandle(thread);
    VirtualFreeEx(process,remote,0,MEM_RELEASE);
    return result ? 0 : 5;
}

#ifdef BRIDGE_DLL
static HMODULE self;
static wchar_t shadow[512];
static CRITICAL_SECTION guard;
typedef struct { HKEY key; wchar_t path[1024]; int machine; } KeyPath;
static KeyPath tracked[512];
static LSTATUS (WINAPI *openW)(HKEY,LPCWSTR,DWORD,REGSAM,PHKEY);
static LSTATUS (WINAPI *createW)(HKEY,LPCWSTR,DWORD,LPWSTR,DWORD,REGSAM,const LPSECURITY_ATTRIBUTES,PHKEY,LPDWORD);
static LSTATUS (WINAPI *closeKey)(HKEY);
static LSTATUS (WINAPI *queryW)(HKEY,LPCWSTR,LPDWORD,LPDWORD,LPBYTE,LPDWORD);
static BOOL (WINAPI *processW)(LPCWSTR,LPWSTR,LPSECURITY_ATTRIBUTES,LPSECURITY_ATTRIBUTES,BOOL,DWORD,LPVOID,LPCWSTR,LPSTARTUPINFOW,LPPROCESS_INFORMATION);
static BOOL (WINAPI *processA)(LPCSTR,LPSTR,LPSECURITY_ATTRIBUTES,LPSECURITY_ATTRIBUTES,BOOL,DWORD,LPVOID,LPCSTR,LPSTARTUPINFOA,LPPROCESS_INFORMATION);
static HMODULE (WINAPI *loadW)(LPCWSTR);
static HMODULE (WINAPI *loadA)(LPCSTR);
static HMODULE (WINAPI *loadExW)(LPCWSTR,HANDLE,DWORD);
static HMODULE (WINAPI *loadExA)(LPCSTR,HANDLE,DWORD);
static void patchAll(void);
static void *replacement(const char *name);
static FARPROC (WINAPI *getProc)(HMODULE,LPCSTR);
static HANDLE (WINAPI *eventW)(LPSECURITY_ATTRIBUTES,BOOL,BOOL,LPCWSTR);
static HANDLE (WINAPI *openEventW)(DWORD,BOOL,LPCWSTR);
static BOOL (WINAPI *enumWindows)(WNDENUMPROC,LPARAM);
static HWND (WINAPI *findWindow)(LPCWSTR,LPCWSTR);
static HWND (WINAPI *findWindowEx)(HWND,HWND,LPCWSTR,LPCWSTR);
static int ownWindow(HWND window){
    DWORD pid;HANDLE process;wchar_t path[MAX_PATH],here[MAX_PATH],*end;DWORD size=MAX_PATH;
    BOOL (WINAPI *query)(HANDLE,DWORD,LPWSTR,PDWORD)=(void*)GetProcAddress(GetModuleHandleW(L"kernel32.dll"),"QueryFullProcessImageNameW");
    GetWindowThreadProcessId(window,&pid);if(pid==GetCurrentProcessId())return 1;
    process=OpenProcess(0x1000,FALSE,pid);if(!process)return 0;
    if(!query(process,0,path,&size)){CloseHandle(process);return 0;}CloseHandle(process);
    GetModuleFileNameW(NULL,here,MAX_PATH);end=wcsrchr(here,L'\\');if(!end)return 0;*end=0;
    return !_wcsnicmp(path,here,wcslen(here));
}
typedef struct {WNDENUMPROC callback;LPARAM data;} EnumContext;
static BOOL CALLBACK filteredWindow(HWND w,LPARAM data){EnumContext *c=(void*)data;return !ownWindow(w) || c->callback(w,c->data);}
static BOOL WINAPI hookEnumWindows(WNDENUMPROC callback,LPARAM data){EnumContext c;c.callback=callback;c.data=data;return enumWindows(filteredWindow,(LPARAM)&c);}
static HWND WINAPI hookFindWindow(LPCWSTR c,LPCWSTR t){HWND w=findWindow(c,t);return w && ownWindow(w)?w:NULL;}
static HWND WINAPI hookFindWindowEx(HWND p,HWND after,LPCWSTR c,LPCWSTR t){HWND w;do{w=findWindowEx(p,after,c,t);if(!w || ownWindow(w))return w;after=w;}while(w);return NULL;}
static HANDLE WINAPI hookEventW(LPSECURITY_ATTRIBUTES a,BOOL m,BOOL i,LPCWSTR name){wchar_t n[1024];if(!name)return eventW(a,m,i,name);swprintf(n,L"%s_CodexPortable_%s",name,wcsrchr(shadow,L'\\')+1);return eventW(a,m,i,n);}
static HANDLE WINAPI hookOpenEventW(DWORD a,BOOL i,LPCWSTR name){wchar_t n[1024];if(!name)return openEventW(a,i,name);swprintf(n,L"%s_CodexPortable_%s",name,wcsrchr(shadow,L'\\')+1);return openEventW(a,i,n);}
static FARPROC WINAPI hookGetProc(HMODULE module,LPCSTR name){
    void *fn;
    if((ULONG_PTR)name>65535){fn=replacement(name);if(fn)return (FARPROC)fn;}
    return getProc(module,name);
}

static int resolve(HKEY key, LPCWSTR sub, wchar_t *path, int *machine) {
    int i,found=0;
    path[0]=0;
    if (key==HKEY_LOCAL_MACHINE || key==HKEY_CURRENT_USER) { *machine=key==HKEY_LOCAL_MACHINE; found=1; }
    else {
        EnterCriticalSection(&guard);
        for(i=0;i<512;i++) if(tracked[i].key==key) { wcscpy(path,tracked[i].path); *machine=tracked[i].machine; found=1; break; }
        LeaveCriticalSection(&guard);
    }
    if(!found) return 0;
    if(sub && *sub) {
        if(wcslen(path)+wcslen(sub)+2>=1024) return 0;
        if(*path) wcscat(path,L"\\");
        wcscat(path,sub);
    }
    return 1;
}
static void remember(HKEY key, LPCWSTR path, int machine) {
    int i;
    EnterCriticalSection(&guard);
    for(i=0;i<512;i++) if(!tracked[i].key || tracked[i].key==key) {tracked[i].key=key;wcscpy(tracked[i].path,path);tracked[i].machine=machine;break;}
    LeaveCriticalSection(&guard);
}
static int vendorPath(LPCWSTR path, LPCWSTR *suffix) {
    LPCWSTR normal=L"SOFTWARE\\NetSarang", wow=L"SOFTWARE\\WOW6432Node\\NetSarang";
    size_t n=wcslen(normal), w=wcslen(wow);
    if(!_wcsnicmp(path,normal,n) && (!path[n] || path[n]==L'\\')) {*suffix=path+n;return 1;}
    if(!_wcsnicmp(path,wow,w) && (!path[w] || path[w]==L'\\')) {*suffix=path+w;return 1;}
    return 0;
}
static LSTATUS WINAPI hookOpenW(HKEY key,LPCWSTR sub,DWORD options,REGSAM access,PHKEY result) {
    wchar_t path[1024],target[1600]; LPCWSTR suffix; int machine; LSTATUS status;
    if(!resolve(key,sub,path,&machine)) return openW(key,sub,options,access,result);
    if(vendorPath(path,&suffix)) {
        swprintf(target,L"%s\\%s\\Software\\NetSarang%s",shadow,machine?L"Machine":L"User",suffix);
        status=openW(HKEY_CURRENT_USER,target,options,access & ~(KEY_WOW64_32KEY|KEY_WOW64_64KEY),result);
    } else status=openW(key,sub,options,access,result);
    if(status==ERROR_SUCCESS) remember(*result,path,machine);
    return status;
}
static LSTATUS WINAPI hookCreateW(HKEY key,LPCWSTR sub,DWORD reserved,LPWSTR cls,DWORD options,REGSAM access,const LPSECURITY_ATTRIBUTES sa,PHKEY result,LPDWORD disposition) {
    wchar_t path[1024],target[1600]; LPCWSTR suffix; int machine; LSTATUS status;
    if(!resolve(key,sub,path,&machine)) return createW(key,sub,reserved,cls,options,access,sa,result,disposition);
    if(vendorPath(path,&suffix)) {
        swprintf(target,L"%s\\%s\\Software\\NetSarang%s",shadow,machine?L"Machine":L"User",suffix);
        status=createW(HKEY_CURRENT_USER,target,reserved,cls,options,access & ~(KEY_WOW64_32KEY|KEY_WOW64_64KEY),sa,result,disposition);
    } else status=createW(key,sub,reserved,cls,options,access,sa,result,disposition);
    if(status==ERROR_SUCCESS) remember(*result,path,machine);
    return status;
}
static void wide(LPCSTR src,wchar_t *out,int capacity) {if(src) MultiByteToWideChar(CP_ACP,0,src,-1,out,capacity);else out[0]=0;}
static LSTATUS WINAPI hookOpenA(HKEY k,LPCSTR s,DWORD o,REGSAM a,PHKEY r) {wchar_t w[1024];wide(s,w,1024);return hookOpenW(k,w,o,a,r);}
static LSTATUS WINAPI hookOpenLegacyW(HKEY k,LPCWSTR s,PHKEY r){return hookOpenW(k,s,0,MAXIMUM_ALLOWED,r);}
static LSTATUS WINAPI hookOpenLegacyA(HKEY k,LPCSTR s,PHKEY r){return hookOpenA(k,s,0,MAXIMUM_ALLOWED,r);}
static LSTATUS WINAPI hookCreateLegacyW(HKEY k,LPCWSTR s,PHKEY r){return hookCreateW(k,s,0,NULL,0,MAXIMUM_ALLOWED,NULL,r,NULL);}
static LSTATUS WINAPI hookCreateA(HKEY k,LPCSTR s,DWORD r,LPSTR cls,DWORD o,REGSAM a,const LPSECURITY_ATTRIBUTES sa,PHKEY out,LPDWORD d) {wchar_t w[1024],c[256];wide(s,w,1024);wide(cls,c,256);return hookCreateW(k,w,r,cls?c:NULL,o,a,sa,out,d);}
static LSTATUS WINAPI hookClose(HKEY key) {int i;EnterCriticalSection(&guard);for(i=0;i<512;i++)if(tracked[i].key==key)tracked[i].key=NULL;LeaveCriticalSection(&guard);return closeKey(key);}
static LSTATUS WINAPI hookQueryW(HKEY key,LPCWSTR name,LPDWORD reserved,LPDWORD type,LPBYTE data,LPDWORD size){
    /* Xshell's COM viewer requires machine registration. Use its documented single-process preference. */
    if(name && !wcscmp(name,L"MultiCoreProcess")){
        if(type)*type=REG_DWORD;
        if(data && size && *size<sizeof(DWORD)){*size=sizeof(DWORD);return ERROR_MORE_DATA;}
        if(data)*(DWORD*)data=0;
        if(size)*size=sizeof(DWORD);
        return ERROR_SUCCESS;
    }
    return queryW(key,name,reserved,type,data,size);
}
static BOOL finishChild(BOOL ok,DWORD flags,LPPROCESS_INFORMATION pi) {
    int error;
    if(!ok) return FALSE;
    error=inject(pi->hProcess,bridge);
    if(error) {TerminateProcess(pi->hProcess,180+error);CloseHandle(pi->hThread);CloseHandle(pi->hProcess);SetLastError(ERROR_DLL_INIT_FAILED);return FALSE;}
    if(!(flags & CREATE_SUSPENDED)) ResumeThread(pi->hThread);
    return TRUE;
}
static BOOL WINAPI hookProcessW(LPCWSTR a,LPWSTR c,LPSECURITY_ATTRIBUTES p,LPSECURITY_ATTRIBUTES t,BOOL i,DWORD f,LPVOID e,LPCWSTR d,LPSTARTUPINFOW s,LPPROCESS_INFORMATION out) {return finishChild(processW(a,c,p,t,i,f|CREATE_SUSPENDED,e,d,s,out),f,out);}
static BOOL WINAPI hookProcessA(LPCSTR a,LPSTR c,LPSECURITY_ATTRIBUTES p,LPSECURITY_ATTRIBUTES t,BOOL i,DWORD f,LPVOID e,LPCSTR d,LPSTARTUPINFOA s,LPPROCESS_INFORMATION out) {return finishChild(processA(a,c,p,t,i,f|CREATE_SUSPENDED,e,d,s,out),f,out);}
static HMODULE WINAPI hookLoadW(LPCWSTR n){HMODULE h=loadW(n);if(h)patchAll();return h;}
static HMODULE WINAPI hookLoadA(LPCSTR n){HMODULE h=loadA(n);if(h)patchAll();return h;}
static HMODULE WINAPI hookLoadExW(LPCWSTR n,HANDLE f,DWORD flags){HMODULE h=loadExW(n,f,flags);if(h && !(flags & (LOAD_LIBRARY_AS_DATAFILE|LOAD_LIBRARY_AS_IMAGE_RESOURCE)))patchAll();return h;}
static HMODULE WINAPI hookLoadExA(LPCSTR n,HANDLE f,DWORD flags){HMODULE h=loadExA(n,f,flags);if(h && !(flags & (LOAD_LIBRARY_AS_DATAFILE|LOAD_LIBRARY_AS_IMAGE_RESOURCE)))patchAll();return h;}
static void *replacement(const char *name) {
    if(!strcmp(name,"RegOpenKeyExW"))return hookOpenW;
    if(!strcmp(name,"GetProcAddress"))return hookGetProc;
    if(!strcmp(name,"CreateEventW"))return hookEventW;
    if(!strcmp(name,"OpenEventW"))return hookOpenEventW;
    if(!strcmp(name,"EnumWindows"))return hookEnumWindows;
    if(!strcmp(name,"FindWindowW"))return hookFindWindow;
    if(!strcmp(name,"FindWindowExW"))return hookFindWindowEx;
    if(!strcmp(name,"RegOpenKeyExA"))return hookOpenA;
    if(!strcmp(name,"RegOpenKeyW"))return hookOpenLegacyW;
    if(!strcmp(name,"RegOpenKeyA"))return hookOpenLegacyA;
    if(!strcmp(name,"RegCreateKeyW"))return hookCreateLegacyW;
    if(!strcmp(name,"RegCreateKeyExW"))return hookCreateW;
    if(!strcmp(name,"RegCreateKeyExA"))return hookCreateA;
    if(!strcmp(name,"RegCloseKey"))return hookClose;
    if(!strcmp(name,"RegQueryValueExW"))return hookQueryW;
    if(!strcmp(name,"CreateProcessW"))return hookProcessW;
    if(!strcmp(name,"CreateProcessA"))return hookProcessA;
    if(!strcmp(name,"LoadLibraryW"))return hookLoadW;
    if(!strcmp(name,"LoadLibraryA"))return hookLoadA;
    if(!strcmp(name,"LoadLibraryExW"))return hookLoadExW;
    if(!strcmp(name,"LoadLibraryExA"))return hookLoadExA;
    return NULL;
}
static void patchModule(HMODULE module) {
    BYTE *base=(BYTE*)module; IMAGE_DOS_HEADER *dos=(IMAGE_DOS_HEADER*)base;IMAGE_NT_HEADERS *nt;IMAGE_IMPORT_DESCRIPTOR *imp;
    if(module==self || dos->e_magic!=IMAGE_DOS_SIGNATURE)return;
    nt=(IMAGE_NT_HEADERS*)(base+dos->e_lfanew);
    if(!nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress)return;
    imp=(IMAGE_IMPORT_DESCRIPTOR*)(base+nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress);
    for(;imp->Name;imp++) {
        IMAGE_THUNK_DATA *names,*iat;
        if(!imp->OriginalFirstThunk)continue;
        names=(IMAGE_THUNK_DATA*)(base+imp->OriginalFirstThunk);iat=(IMAGE_THUNK_DATA*)(base+imp->FirstThunk);
        for(;names->u1.AddressOfData;names++,iat++) {
            void *fn;DWORD protection,old;
            if(IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal))continue;
            fn=replacement((char*)((IMAGE_IMPORT_BY_NAME*)(base+names->u1.AddressOfData))->Name);
            if(fn && iat->u1.Function!=(DWORD)fn && VirtualProtect(&iat->u1.Function,sizeof(DWORD),PAGE_READWRITE,&protection)) {
                InterlockedExchange((LONG*)&iat->u1.Function,(LONG)fn);VirtualProtect(&iat->u1.Function,sizeof(DWORD),protection,&old);
            }
        }
    }
}
static void patchAll(void) {
    HANDLE snapshot=CreateToolhelp32Snapshot(TH32CS_SNAPMODULE,GetCurrentProcessId());MODULEENTRY32W m;
    BOOL (WINAPI *first)(HANDLE,MODULEENTRY32W*)=(void*)GetProcAddress(GetModuleHandleW(L"kernel32.dll"),"Module32FirstW");
    BOOL (WINAPI *next)(HANDLE,MODULEENTRY32W*)=(void*)GetProcAddress(GetModuleHandleW(L"kernel32.dll"),"Module32NextW");
    wchar_t windows[MAX_PATH];GetWindowsDirectoryW(windows,MAX_PATH);
    if(snapshot==INVALID_HANDLE_VALUE)return;
    m.dwSize=sizeof(m);
    if(first(snapshot,&m))do {
        /* OS modules stay untouched; vendor, CRT and application imports are routed. */
        if(_wcsnicmp(m.szExePath,windows,wcslen(windows)))patchModule(m.hModule);
    }while(next(snapshot,&m));
    CloseHandle(snapshot);
}
BOOL WINAPI DllMain(HINSTANCE instance,DWORD reason,LPVOID reserved) {
    if(reason==DLL_PROCESS_ATTACH) {
        HMODULE adv=GetModuleHandleW(L"advapi32.dll"),kernel=GetModuleHandleW(L"kernel32.dll");
        self=instance;GetModuleFileNameW(instance,bridge,MAX_PATH);
        if(!GetEnvironmentVariableW(L"NS_PORTABLE_REGISTRY",shadow,512))return FALSE;
        InitializeCriticalSection(&guard);
        if(!adv)adv=LoadLibraryW(L"advapi32.dll");
        openW=(void*)GetProcAddress(adv,"RegOpenKeyExW");createW=(void*)GetProcAddress(adv,"RegCreateKeyExW");closeKey=(void*)GetProcAddress(adv,"RegCloseKey");
        queryW=(void*)GetProcAddress(adv,"RegQueryValueExW");
        getProc=(void*)GetProcAddress(kernel,"GetProcAddress");
        eventW=(void*)GetProcAddress(kernel,"CreateEventW");openEventW=(void*)GetProcAddress(kernel,"OpenEventW");enumWindows=(void*)GetProcAddress(GetModuleHandleW(L"user32.dll"),"EnumWindows");
        findWindow=(void*)GetProcAddress(GetModuleHandleW(L"user32.dll"),"FindWindowW");findWindowEx=(void*)GetProcAddress(GetModuleHandleW(L"user32.dll"),"FindWindowExW");
        processW=(void*)GetProcAddress(kernel,"CreateProcessW");processA=(void*)GetProcAddress(kernel,"CreateProcessA");
        loadW=(void*)GetProcAddress(kernel,"LoadLibraryW");loadA=(void*)GetProcAddress(kernel,"LoadLibraryA");loadExW=(void*)GetProcAddress(kernel,"LoadLibraryExW");loadExA=(void*)GetProcAddress(kernel,"LoadLibraryExA");
        patchAll();
    }
    return TRUE;
}
#else
int main(int argc,char **argv) {
    wchar_t exe[MAX_PATH],command[2*MAX_PATH+8],*slash,*args;int length=0;
    STARTUPINFOW startup;PROCESS_INFORMATION pi;DWORD code;int error;
    if(argc<2)return 2;
    GetModuleFileNameW(NULL,bridge,MAX_PATH);slash=wcsrchr(bridge,L'\\');if(!slash)return 3;wcscpy(slash+1,L"registry-bridge.dll");
    args=GetCommandLineW();
    if(*args==L'"'){args++;while(*args && *args!=L'"')args++;if(*args)args++;}
    else while(*args && *args!=L' ')args++;
    while(*args==L' ')args++;
    if(*args==L'"'){args++;while(*args && *args!=L'"' && length<MAX_PATH-1)exe[length++]=*args++;}
    else while(*args && *args!=L' ' && length<MAX_PATH-1)exe[length++]=*args++;
    exe[length]=0;if(!length)return 2;
    swprintf(command,L"\"%s\"%s",exe,argc>2?L" -newwin":L"");
    ZeroMemory(&startup,sizeof(startup));ZeroMemory(&pi,sizeof(pi));startup.cb=sizeof(startup);
    if(!CreateProcessW(exe,command,NULL,NULL,FALSE,CREATE_SUSPENDED,NULL,NULL,&startup,&pi))return 10;
    error=inject(pi.hProcess,bridge);
    if(error){TerminateProcess(pi.hProcess,180+error);CloseHandle(pi.hThread);CloseHandle(pi.hProcess);return 180+error;}
    ResumeThread(pi.hThread);WaitForSingleObject(pi.hProcess,INFINITE);GetExitCodeProcess(pi.hProcess,&code);
    CloseHandle(pi.hThread);CloseHandle(pi.hProcess);return (int)code;
}
#endif
