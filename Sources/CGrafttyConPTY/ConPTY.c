#include "GrafttyConPTY.h"

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>
#include <stdlib.h>
#include <string.h>

struct graftty_conpty {
    HPCON console;
    HANDLE input;
    HANDLE output;
    HANDLE process;
    HANDLE reader;
    DWORD reader_id;
    SRWLOCK lock;
    SRWLOCK write_lock;
    CONDITION_VARIABLE condition;
    unsigned writers;
    int reader_done;
    int closing;
    int closed;
    graftty_conpty_output callback;
    void *context;
};

static uint32_t hresult_error(HRESULT result) {
    return HRESULT_FACILITY(result) == FACILITY_WIN32 ? HRESULT_CODE(result) : (uint32_t)result;
}

static DWORD WINAPI drain_output(void *context) {
    graftty_conpty *session = context;
    uint8_t buffer[16384];
    DWORD count;
    while (ReadFile(session->output, buffer, sizeof(buffer), &count, NULL) && count != 0) {
        session->callback(session->context, buffer, count);
    }
    AcquireSRWLockExclusive(&session->lock);
    session->reader_done = 1;
    ReleaseSRWLockExclusive(&session->lock);
    return 0;
}

uint32_t graftty_conpty_create(const uint16_t *executable, const uint16_t *command,
    const uint16_t *directory, const uint16_t *environment, int16_t columns,
    int16_t rows, graftty_conpty_output output, void *context, graftty_conpty **result) {
    if (result == NULL) return ERROR_INVALID_PARAMETER;
    *result = NULL;
    if (!executable || !*executable || !command || !directory || !output || columns < 1 || rows < 1)
        return ERROR_INVALID_PARAMETER;
    graftty_conpty *session = calloc(1, sizeof(*session));
    if (!session) return ERROR_OUTOFMEMORY;
    InitializeSRWLock(&session->lock);
    InitializeSRWLock(&session->write_lock);
    InitializeConditionVariable(&session->condition);
    session->callback = output;
    session->context = context;
    HANDLE input_read = NULL, output_write = NULL;
    STARTUPINFOEXW startup = {0};
    PROCESS_INFORMATION process = {0};
    SIZE_T attribute_size = 0;
    uint32_t error = 0;
    wchar_t *mutable_command = NULL;
    int attributes_initialized = 0;
    if (!CreatePipe(&input_read, &session->input, NULL, 0) ||
        !CreatePipe(&session->output, &output_write, NULL, 0)) {
        error = GetLastError(); goto cleanup;
    }
    // Drain before CreateProcess: startup and ClosePseudoConsole can emit VT
    // data, and must never wait for a reader running on the caller's thread.
    session->reader = CreateThread(NULL, 0, drain_output, session, 0, &session->reader_id);
    if (!session->reader) { error = GetLastError(); goto cleanup; }
    HRESULT hr = CreatePseudoConsole((COORD){columns, rows}, input_read, output_write, 0, &session->console);
    if (FAILED(hr)) { error = hresult_error(hr); goto cleanup; }
    InitializeProcThreadAttributeList(NULL, 1, 0, &attribute_size);
    startup.lpAttributeList = HeapAlloc(GetProcessHeap(), 0, attribute_size);
    if (!startup.lpAttributeList) { error = ERROR_OUTOFMEMORY; goto cleanup; }
    if (!InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &attribute_size)) {
        error = GetLastError(); goto cleanup;
    }
    attributes_initialized = 1;
    if (!UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        session->console, sizeof(session->console), NULL, NULL)) {
        error = GetLastError(); goto cleanup;
    }
    size_t length = wcslen((const wchar_t *)command) + 1;
    mutable_command = malloc(length * sizeof(wchar_t));
    if (!mutable_command) { error = ERROR_OUTOFMEMORY; goto cleanup; }
    memcpy(mutable_command, command, length * sizeof(wchar_t));
    startup.StartupInfo.cb = sizeof(startup);
    if (!CreateProcessW((const wchar_t *)executable, mutable_command, NULL, NULL, FALSE,
        EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT, (void *)environment,
        (const wchar_t *)directory, &startup.StartupInfo, &process)) {
        error = GetLastError(); goto cleanup;
    }
    session->process = process.hProcess;
    CloseHandle(process.hThread);
cleanup:
    free(mutable_command);
    if (attributes_initialized) DeleteProcThreadAttributeList(startup.lpAttributeList);
    if (startup.lpAttributeList) HeapFree(GetProcessHeap(), 0, startup.lpAttributeList);
    if (input_read) CloseHandle(input_read);
    if (output_write) CloseHandle(output_write);
    if (error) {
        graftty_conpty_destroy(session);
        return error;
    }
    *result = session;
    return 0;
}

uint32_t graftty_conpty_write(graftty_conpty *session, const uint8_t *bytes, size_t count) {
    if (!session || (!bytes && count)) return ERROR_INVALID_PARAMETER;
    // Serialize complete writes so chunks from separate callers do not mix.
    AcquireSRWLockExclusive(&session->write_lock);
    AcquireSRWLockExclusive(&session->lock);
    if (session->closing) {
        ReleaseSRWLockExclusive(&session->lock);
        ReleaseSRWLockExclusive(&session->write_lock);
        return ERROR_OPERATION_ABORTED;
    }
    session->writers++;
    ReleaseSRWLockExclusive(&session->lock);
    uint32_t error = 0;
    while (count) {
        DWORD written = 0;
        DWORD chunk = count > 65536 ? 65536 : (DWORD)count;
        if (!WriteFile(session->input, bytes, chunk, &written, NULL)) { error = GetLastError(); break; }
        if (!written) { error = ERROR_BROKEN_PIPE; break; }
        bytes += written;
        count -= written;
    }
    AcquireSRWLockExclusive(&session->lock);
    session->writers--;
    WakeAllConditionVariable(&session->condition);
    ReleaseSRWLockExclusive(&session->lock);
    ReleaseSRWLockExclusive(&session->write_lock);
    return error;
}

uint32_t graftty_conpty_resize(graftty_conpty *session, int16_t columns, int16_t rows) {
    if (!session || columns < 1 || rows < 1) return ERROR_INVALID_PARAMETER;
    AcquireSRWLockExclusive(&session->lock);
    uint32_t error = session->closing ? ERROR_OPERATION_ABORTED :
        hresult_error(ResizePseudoConsole(session->console, (COORD){columns, rows}));
    ReleaseSRWLockExclusive(&session->lock);
    return error;
}

uint32_t graftty_conpty_wait(graftty_conpty *session, uint32_t milliseconds, uint32_t *exit_code) {
    if (!session || !exit_code) return ERROR_INVALID_PARAMETER;
    // The process handle remains open until destroy, even after close.
    if (!session->process) return ERROR_INVALID_HANDLE;
    DWORD result = WaitForSingleObject(session->process, milliseconds);
    if (result == WAIT_TIMEOUT) return ERROR_TIMEOUT;
    if (result != WAIT_OBJECT_0) return GetLastError();
    DWORD native_exit_code = 0;
    if (!GetExitCodeProcess(session->process, &native_exit_code)) return GetLastError();
    *exit_code = (uint32_t)native_exit_code;
    return 0;
}

uint32_t graftty_conpty_close(graftty_conpty *session) {
    if (!session) return ERROR_INVALID_PARAMETER;
    AcquireSRWLockExclusive(&session->lock);
    if (GetCurrentThreadId() == session->reader_id && !session->reader_done) {
        ReleaseSRWLockExclusive(&session->lock);
        return ERROR_POSSIBLE_DEADLOCK;
    }
    if (session->closing) {
        while (!session->closed) SleepConditionVariableSRW(&session->condition, &session->lock, INFINITE, 0);
        ReleaseSRWLockExclusive(&session->lock);
        return 0;
    }
    session->closing = 1;
    ReleaseSRWLockExclusive(&session->lock);
    // The reader keeps draining throughout shutdown. Closing ConPTY ends the
    // process tree and breaks blocked input writes before their handle closes.
    if (session->console) ClosePseudoConsole(session->console);
    AcquireSRWLockExclusive(&session->lock);
    while (session->writers) SleepConditionVariableSRW(&session->condition, &session->lock, INFINITE, 0);
    ReleaseSRWLockExclusive(&session->lock);
    if (session->reader) WaitForSingleObject(session->reader, INFINITE);
    if (session->input) CloseHandle(session->input);
    if (session->output) CloseHandle(session->output);
    if (session->reader) CloseHandle(session->reader);
    AcquireSRWLockExclusive(&session->lock);
    session->closed = 1;
    WakeAllConditionVariable(&session->condition);
    ReleaseSRWLockExclusive(&session->lock);
    return 0;
}

void graftty_conpty_destroy(graftty_conpty *session) {
    if (!session) return;
    // Destroying from the output callback would free its own active reader.
    if (graftty_conpty_close(session) != 0) return;
    if (session->process) CloseHandle(session->process);
    free(session);
}
#endif
