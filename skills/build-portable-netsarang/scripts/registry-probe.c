#include <windows.h>
#include <stdio.h>
#include <string.h>
int main(int argc,char **argv) {
    HKEY key;DWORD type,size=256;char value[256],child[16];LONG status;
    status=RegOpenKeyExA(HKEY_LOCAL_MACHINE,"SOFTWARE\\NetSarang\\Probe",0,KEY_READ,&key);
    if(status){printf("open=%ld\n",status);return 1;}
    status=RegQueryValueExA(key,"Sentinel",NULL,&type,(BYTE*)value,&size);RegCloseKey(key);
    printf("value=%s status=%ld\n",value,status);
    if(!GetEnvironmentVariableA("NS_PROBE_CHILD",child,16)) {
        STARTUPINFOA startup={0};PROCESS_INFORMATION process={0};char command[1024];
        SetEnvironmentVariableA("NS_PROBE_CHILD","1");startup.cb=sizeof(startup);
        sprintf(command,"\"%s\"",argv[0]);
        if(!CreateProcessA(NULL,command,NULL,NULL,FALSE,0,NULL,NULL,&startup,&process))return 3;
        if(WaitForSingleObject(process.hProcess,10000)!=WAIT_OBJECT_0){TerminateProcess(process.hProcess,4);return 4;}
        GetExitCodeProcess(process.hProcess,&size);CloseHandle(process.hProcess);CloseHandle(process.hThread);return size;
    }
    return status || strcmp(value,"user-only");
}
