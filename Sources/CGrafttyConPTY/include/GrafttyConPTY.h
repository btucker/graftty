#ifndef GRAFTTY_CONPTY_H
#define GRAFTTY_CONPTY_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct graftty_conpty graftty_conpty;
// Called on the dedicated output thread. Copy bytes before returning. The
// callback must drain promptly and must not invoke session APIs.
typedef void (*graftty_conpty_output)(void *, const uint8_t *, size_t);

uint32_t graftty_conpty_create(const uint16_t *executable, const uint16_t *command,
    const uint16_t *directory, const uint16_t *environment, int16_t columns,
    int16_t rows, graftty_conpty_output output, void *context, graftty_conpty **session);
uint32_t graftty_conpty_write(graftty_conpty *session, const uint8_t *bytes, size_t count);
uint32_t graftty_conpty_resize(graftty_conpty *session, int16_t columns, int16_t rows);
// Returns ERROR_TIMEOUT if still running, otherwise the Win32 wait error or 0.
uint32_t graftty_conpty_wait(graftty_conpty *session, uint32_t milliseconds, uint32_t *exit_code);
// Idempotent and safe against concurrent write/resize/wait calls. Stops the
// console process tree and drains output before returning.
uint32_t graftty_conpty_close(graftty_conpty *session);
// Call only after every API caller has returned. Calls close before freeing.
void graftty_conpty_destroy(graftty_conpty *session);

#ifdef __cplusplus
}
#endif
#endif
