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
#ifdef BRIDGE_TRACE
/* Optional diagnostic build only; the shipped DLL never writes a trace file. */
static void traceA(const char *tag,const char *text){
    wchar_t path[MAX_PATH];HANDLE h;DWORD written;char line[2048];int n;
    GetTempPathW(MAX_PATH,path);wcscat(path,L"ns-bridge-trace.log");
    h=CreateFileW(path,GENERIC_WRITE,FILE_SHARE_READ|FILE_SHARE_WRITE,NULL,OPEN_ALWAYS,0,NULL);
    if(h==INVALID_HANDLE_VALUE)return;
    SetFilePointer(h,0,NULL,FILE_END);
    n=sprintf(line,"[pid=%lu] %s %s\r\n",(unsigned long)GetCurrentProcessId(),tag,text?text:"");
    if(n>0)WriteFile(h,line,(DWORD)n,&written,NULL);
    CloseHandle(h);
}
static void traceW(const char *tag,const wchar_t *text){
    char buf[1024];int i;if(!text){traceA(tag,"(null)");return;}
    for(i=0;i<1023&&text[i];i++)buf[i]=(char)((text[i]<128&&text[i]>31)?text[i]:'?');
    buf[i]=0;traceA(tag,buf);
}
#else
#define traceA(t,x) ((void)0)
#define traceW(t,x) ((void)0)
#endif
/* SHELLEXECUTEINFO x86 layout; shellapi.h is excluded by WIN32_LEAN_AND_MEAN. */
typedef struct {
    DWORD cbSize;ULONG fMask;HWND hwnd;
    const void *lpVerb,*lpFile,*lpParameters,*lpDirectory;
    int nShow;HINSTANCE hInstApp;void *lpIDList;const void *lpClass;
    HKEY hkeyClass;DWORD dwHotKey;HANDLE hIcon;HANDLE hProcess;
} ShellInfo;
#define SEE_MASK_NOCLOSEPROCESS 0x40
static BOOL (WINAPI *shellExW)(ShellInfo*);
static BOOL (WINAPI *shellExA)(ShellInfo*);
static HINSTANCE (WINAPI *shellW)(HWND,LPCWSTR,LPCWSTR,LPCWSTR,LPCWSTR,int);
static HINSTANCE (WINAPI *shellA)(HWND,LPCSTR,LPCSTR,LPCSTR,LPCSTR,int);
static UINT (WINAPI *winExecFn)(LPCSTR,UINT);
typedef struct { HKEY key; wchar_t path[1024]; int machine; } KeyPath;
static KeyPath tracked[512];
static LSTATUS (WINAPI *openW)(HKEY,LPCWSTR,DWORD,REGSAM,PHKEY);
static LSTATUS (WINAPI *createW)(HKEY,LPCWSTR,DWORD,LPWSTR,DWORD,REGSAM,const LPSECURITY_ATTRIBUTES,PHKEY,LPDWORD);
static LSTATUS (WINAPI *closeKey)(HKEY);
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
    target[0]=0;
    if(!resolve(key,sub,path,&machine)){traceW("REG_OPEN_PASSTHROUGH",sub?sub:L"(null)");return openW(key,sub,options,access,result);}
    if(vendorPath(path,&suffix)) {
        swprintf(target,L"%s\\%s\\Software\\NetSarang%s",shadow,machine?L"Machine":L"User",suffix);
        status=openW(HKEY_CURRENT_USER,target,options,access & ~(KEY_WOW64_32KEY|KEY_WOW64_64KEY),result);
    } else status=openW(key,sub,options,access,result);
    if(status==ERROR_SUCCESS) remember(*result,path,machine);
#ifdef BRIDGE_TRACE
    traceW("REG_OPEN",sub?sub:L"(null)");traceW("REG_TARGET",target[0]?target:L"(direct)");
    { char s[64]; sprintf(s,"status=%ld",(long)status); traceA("REG_STATUS",s); }
#endif
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
static BOOL finishChild(BOOL ok,DWORD flags,LPPROCESS_INFORMATION pi) {
    int error;
    if(!ok) return FALSE;
    error=inject(pi->hProcess,bridge);
    if(error) {TerminateProcess(pi->hProcess,180+error);CloseHandle(pi->hThread);CloseHandle(pi->hProcess);SetLastError(ERROR_DLL_INIT_FAILED);return FALSE;}
    if(!(flags & CREATE_SUSPENDED)) ResumeThread(pi->hThread);
    return TRUE;
}
static BOOL WINAPI hookProcessW(LPCWSTR a,LPWSTR c,LPSECURITY_ATTRIBUTES p,LPSECURITY_ATTRIBUTES t,BOOL i,DWORD f,LPVOID e,LPCWSTR d,LPSTARTUPINFOW s,LPPROCESS_INFORMATION out) {traceW("CREATEPROCESS_W",a?a:c);return finishChild(processW(a,c,p,t,i,f|CREATE_SUSPENDED,e,d,s,out),f,out);}
static BOOL WINAPI hookProcessA(LPCSTR a,LPSTR c,LPSECURITY_ATTRIBUTES p,LPSECURITY_ATTRIBUTES t,BOOL i,DWORD f,LPVOID e,LPCSTR d,LPSTARTUPINFOA s,LPPROCESS_INFORMATION out) {traceA("CREATEPROCESS_A",a?a:(c?c:""));return finishChild(processA(a,c,p,t,i,f|CREATE_SUSPENDED,e,d,s,out),f,out);}
static int exeSuffixW(LPCWSTR f){size_t n;if(!f)return 0;n=wcslen(f);if(n<4)return 0;return f[n-4]==L'.'&&(f[n-3]==L'e'||f[n-3]==L'E')&&(f[n-2]==L'x'||f[n-2]==L'X')&&(f[n-1]==L'e'||f[n-1]==L'E');}
static int exeSuffixA(LPCSTR f){size_t n;if(!f)return 0;n=strlen(f);if(n<4)return 0;return f[n-4]=='.'&&(f[n-3]=='e'||f[n-3]=='E')&&(f[n-2]=='x'||f[n-2]=='X')&&(f[n-1]=='e'||f[n-1]=='E');}
static int openVerb(LPCWSTR v){return !v||!*v||!_wcsicmp(v,L"open");}
/* ShellExecute/WinExec bypass the CreateProcess IAT. Reproduce them with a
 * suspended start, inject the same bridge, then resume, so viewer children
 * share the portable registry namespace instead of falling back to the host. */
static void qualifyW(LPCWSTR file,wchar_t *out){
    wchar_t here[MAX_PATH],*slash;
    if(!file){out[0]=0;return;}
    if(wcschr(file,L'\\')||wcschr(file,L'/')){wcsncpy(out,file,MAX_PATH-1);out[MAX_PATH-1]=0;return;}
    here[0]=0;GetModuleFileNameW(NULL,here,MAX_PATH);
    slash=wcsrchr(here,L'\\');if(slash)*(slash+1)=0;
    swprintf(out,L"%s%s",here,file);
}
static BOOL spawnInjectedW(LPCWSTR file,LPCWSTR params,LPCWSTR dir,int show,HANDLE *outProc){
    wchar_t qualified[MAX_PATH],command[4096],workdir[MAX_PATH],*slash;STARTUPINFOW startup;PROCESS_INFORMATION pi;int error;
    if(!file||!*file)return FALSE;
    qualifyW(file,qualified);
    /* ShellExecute uses the executable's own folder when lpDirectory is NULL;
     * mirroring that avoids breaking children that resolve resources relatively. */
    if(dir&&*dir)wcsncpy(workdir,dir,MAX_PATH-1),workdir[MAX_PATH-1]=0;
    else{wcsncpy(workdir,qualified,MAX_PATH-1);workdir[MAX_PATH-1]=0;slash=wcsrchr(workdir,L'\\');if(slash)*slash=0;}
    swprintf(command,L"\"%s\"%s%s",qualified,params&&*params?L" ":L"",params?params:L"");
    ZeroMemory(&startup,sizeof(startup));startup.cb=sizeof(startup);
    startup.dwFlags=STARTF_USESHOWWINDOW;startup.wShowWindow=(WORD)show;
    ZeroMemory(&pi,sizeof(pi));
    traceW("SPAWN_CMD",command);
    traceW("SPAWN_DIR",workdir);
    if(!processW(qualified,command,NULL,NULL,FALSE,CREATE_SUSPENDED,NULL,workdir,&startup,&pi)){traceA("SPAWN_FAILED","CreateProcessW");return FALSE;}
    error=inject(pi.hProcess,bridge);
    if(error){TerminateProcess(pi.hProcess,180+error);CloseHandle(pi.hThread);CloseHandle(pi.hProcess);return FALSE;}
    ResumeThread(pi.hThread);
    if(outProc)*outProc=pi.hProcess;else CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return TRUE;
}
static BOOL WINAPI hookShellExW(ShellInfo *info){
    HANDLE child=NULL;
    if(!info||!info->lpFile||!exeSuffixW((LPCWSTR)info->lpFile)||!openVerb((LPCWSTR)info->lpVerb)||info->lpIDList)
        return shellExW?shellExW(info):FALSE;
    traceW("SHELLEXEC_EX_W",(LPCWSTR)info->lpFile);
    traceW("SEX_VERB",(LPCWSTR)info->lpVerb);
    traceW("SEX_PARAMS",(LPCWSTR)info->lpParameters);
    traceW("SEX_DIR",(LPCWSTR)info->lpDirectory);
#ifdef BRIDGE_TRACE
    { char m[160]; sprintf(m,"fMask=0x%lX nShow=%d cbSize=%lu lpIDList=%p",(unsigned long)info->fMask,info->nShow,(unsigned long)info->cbSize,info->lpIDList); traceA("SEX_MASK",m); }
#endif
    if(!spawnInjectedW((LPCWSTR)info->lpFile,(LPCWSTR)info->lpParameters,(LPCWSTR)info->lpDirectory,info->nShow,&child))return FALSE;
    if(info->fMask&SEE_MASK_NOCLOSEPROCESS)info->hProcess=child;else if(child)CloseHandle(child);
    info->hInstApp=(HINSTANCE)42;
    return TRUE;
}
static BOOL WINAPI hookShellExA(ShellInfo *info){
    wchar_t verb[64],file[MAX_PATH],params[2048],dir[MAX_PATH];HANDLE child=NULL;
    if(!info||!info->lpFile)return shellExA?shellExA(info):FALSE;
    wide((LPCSTR)info->lpVerb,verb,64);wide((LPCSTR)info->lpFile,file,MAX_PATH);
    if(!exeSuffixW(file)||!openVerb(verb)||info->lpIDList)return shellExA?shellExA(info):FALSE;
    wide((LPCSTR)info->lpParameters,params,2048);wide((LPCSTR)info->lpDirectory,dir,MAX_PATH);
    traceW("SHELLEXEC_EX_A",file);
    if(!spawnInjectedW(file,params[0]?params:NULL,dir[0]?dir:NULL,info->nShow,&child))return FALSE;
    if(info->fMask&SEE_MASK_NOCLOSEPROCESS)info->hProcess=child;else if(child)CloseHandle(child);
    info->hInstApp=(HINSTANCE)42;
    return TRUE;
}
static HINSTANCE WINAPI hookShellW(HWND h,LPCWSTR verb,LPCWSTR file,LPCWSTR params,LPCWSTR dir,int show){
    if(exeSuffixW(file)&&openVerb(verb)){
        traceW("SHELLEXEC_W",file);
        return spawnInjectedW(file,params,dir,show,NULL)?(HINSTANCE)42:(HINSTANCE)31;
    }
    return shellW?shellW(h,verb,file,params,dir,show):(HINSTANCE)0;
}
static HINSTANCE WINAPI hookShellA(HWND h,LPCSTR verb,LPCSTR file,LPCSTR params,LPCSTR dir,int show){
    wchar_t wv[64],wf[MAX_PATH],wp[2048],wd[MAX_PATH];
    wide(verb,wv,64);wide(file,wf,MAX_PATH);
    if(exeSuffixW(wf)&&openVerb(wv)){
        wide(params,wp,2048);wide(dir,wd,MAX_PATH);
        traceW("SHELLEXEC_A",wf);
        return spawnInjectedW(wf,wp[0]?wp:NULL,wd[0]?wd:NULL,show,NULL)?(HINSTANCE)42:(HINSTANCE)31;
    }
    return shellA?shellA(h,verb,file,params,dir,show):(HINSTANCE)0;
}
static UINT WINAPI hookWinExec(LPCSTR command,UINT show){
    const char *p=command;char file[MAX_PATH];int n=0;wchar_t wf[MAX_PATH],wp[2048];
    if(!command)return winExecFn?winExecFn(command,show):0;
    if(*p=='"'){p++;while(*p&&*p!='"'&&n<MAX_PATH-1)file[n++]=*p++;if(*p=='"')p++;}
    else while(*p&&*p!=' '&&*p!='\t'&&n<MAX_PATH-1)file[n++]=*p++;
    file[n]=0;
    if(!exeSuffixA(file))return winExecFn?winExecFn(command,show):0;
    wide(file,wf,MAX_PATH);wide(p,wp,2048);
    traceA("WINEXEC",file);
    if(spawnInjectedW(wf,wp[0]?wp:NULL,NULL,(int)show,NULL))return 33;
    return winExecFn?winExecFn(command,show):0;
}
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
    if(!strcmp(name,"CreateProcessW"))return hookProcessW;
    if(!strcmp(name,"CreateProcessA"))return hookProcessA;
    if(!strcmp(name,"ShellExecuteExW"))return hookShellExW;
    if(!strcmp(name,"ShellExecuteExA"))return hookShellExA;
    if(!strcmp(name,"ShellExecuteW"))return hookShellW;
    if(!strcmp(name,"ShellExecuteA"))return hookShellA;
    if(!strcmp(name,"WinExec"))return hookWinExec;
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
                traceA("PATCH",((IMAGE_IMPORT_BY_NAME*)(base+names->u1.AddressOfData))->Name);
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
    traceW("PATCHALL_BEGIN",shadow);
    if(first(snapshot,&m))do {
        traceW("MODULE",m.szExePath);
        /* OS modules stay untouched; vendor, CRT and application imports are routed. */
        if(_wcsnicmp(m.szExePath,windows,wcslen(windows)))patchModule(m.hModule);
    }while(next(snapshot,&m));
    CloseHandle(snapshot);
}
BOOL WINAPI DllMain(HINSTANCE instance,DWORD reason,LPVOID reserved) {
    if(reason==DLL_PROCESS_ATTACH) {
        HMODULE adv=GetModuleHandleW(L"advapi32.dll"),kernel=GetModuleHandleW(L"kernel32.dll");
        HMODULE shell;
        self=instance;GetModuleFileNameW(instance,bridge,MAX_PATH);
        if(!GetEnvironmentVariableW(L"NS_PORTABLE_REGISTRY",shadow,512)){traceA("NO_ENV","NS_PORTABLE_REGISTRY missing");return FALSE;}
        traceW("ATTACH",shadow);
        InitializeCriticalSection(&guard);
        if(!adv)adv=LoadLibraryW(L"advapi32.dll");
        /* Resolve launch APIs before patchAll so GetProcAddress is not rerouted. */
        shell=GetModuleHandleW(L"shell32.dll");
        if(shell){
            shellExW=(void*)GetProcAddress(shell,"ShellExecuteExW");
            shellExA=(void*)GetProcAddress(shell,"ShellExecuteExA");
            shellW=(void*)GetProcAddress(shell,"ShellExecuteW");
            shellA=(void*)GetProcAddress(shell,"ShellExecuteA");
        }
        winExecFn=(void*)GetProcAddress(kernel,"WinExec");
        openW=(void*)GetProcAddress(adv,"RegOpenKeyExW");createW=(void*)GetProcAddress(adv,"RegCreateKeyExW");closeKey=(void*)GetProcAddress(adv,"RegCloseKey");
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
