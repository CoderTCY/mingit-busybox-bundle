/* SPDX-License-Identifier: GPL-2.0-only */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>
#include <objbase.h>
#include <stdio.h>

int wmain(int argc, wchar_t **argv)
{
    HRESULT result;
    int status = 0;

    if (argc < 2) {
        fwprintf(stderr, L"Usage: mingit-open <path-or-url> [...]\n");
        return 2;
    }
    result = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (FAILED(result)) {
        fwprintf(stderr, L"COM STA initialization failed (HRESULT 0x%08lx)\n", (unsigned long)result);
        return 1;
    }
    for (int i = 1; i < argc; i++) {
        INT_PTR opened = (INT_PTR)ShellExecuteW(NULL, L"open", argv[i], NULL, NULL, SW_SHOWNORMAL);
        if (opened <= 32) {
            fwprintf(stderr, L"Cannot open '%ls' with the Windows default application (ShellExecute error %lld)\n",
                     argv[i], (long long)opened);
            status = 1;
        }
    }
    CoUninitialize();
    return status;
}
