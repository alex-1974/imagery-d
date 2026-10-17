/* Issue #74: Linux/glibc-only research malloc/free trace interposer.
 * Enabled only after explicit m3_trace_stage() from the research D consumer.
 * Trace format: ACTION,PHASE,POINTER,REQUESTED_BYTES,INTENT_KIND.
 * Pointer hex is only an ephemeral ID, not retained by the probe.
 *
 * This deliberately uses glibc __libc_* implementation entry points:
 * NONPORTABLE and NEVER for a production or installed package.
 * Only symbol-interposed libc calls on the invoking D thread are seen.
 * Internal libc allocator operations, mmap bypasses, GC worker threads,
 * alternative allocators and stack memory are OUTSIDE this evidence.
 */
#define _GNU_SOURCE
#include <stdint.h>
#include <stddef.h>
#include <errno.h>
#include <sys/syscall.h>
#include <unistd.h>

extern void *__libc_malloc(size_t);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_realloc(void *, size_t);
extern void __libc_free(void *);
extern void *__libc_memalign(size_t, size_t);

static __thread unsigned phase_;
static __thread unsigned pending_kind_;
static __thread size_t pending_bytes_;
static __thread unsigned recording_;
enum { trace_fd = 9 };

static char *decimal(char *p, size_t n)
{
    char digits[32];
    unsigned k = 0;
    do { digits[k++] = (char)('0' + n % 10); n /= 10; } while (n);
    while (k) *p++ = digits[--k];
    return p;
}
static char *pointer_hex(char *p, uintptr_t n)
{
    static const char table[] = "0123456789abcdef";
    *p++ = '0'; *p++ = 'x';
    for (int i = (int)(sizeof(uintptr_t) * 2) - 1; i >= 0; --i)
        *p++ = table[(n >> (i * 4)) & 15u];
    return p;
}
static void emit(char action, uintptr_t ptr, size_t requested, unsigned kind)
{
    if (!phase_ || recording_) return;
    recording_ = 1;
    char buf[160];
    char *p = buf;
    *p++ = action; *p++ = ',';
    p = decimal(p, phase_); *p++ = ',';
    p = pointer_hex(p, ptr); *p++ = ',';
    p = decimal(p, requested); *p++ = ',';
    p = decimal(p, kind); *p++ = '\n';
    (void)syscall(SYS_write, trace_fd, buf, (size_t)(p - buf));
    recording_ = 0;
}

/* Marker calls are resolved using dlsym from the independent consumer.
 * A value of 0 terminates tracing; no malloc bookkeeping is introduced. */
__attribute__((visibility("default")))
void m3_trace_stage(unsigned phase)
{
    if (phase > 31) return;
    if (phase_) emit('E', 0, phase, 0);
    phase_ = phase;
    pending_kind_ = 0; pending_bytes_ = 0;
    if (phase_) emit('S', 0, 0, 0);
}

/* Research-only opaque pixel touch: the direct raw malloc control
 * must actually materialize both scratch and packed buffers under
 * optimized LDC builds. The dynamically resolved external function
 * keeps the scratch pointer observable until AFTER packed allocation,
 * without allocating or creating another trace event. */
__attribute__((visibility("default")))
void m3_trace_touch(void *storage, size_t bytes)
{
    if (!storage || !bytes) return;
    volatile unsigned char *samples = (volatile unsigned char *)storage;
    samples[0] = 13u;
    samples[bytes - 1] = 37u;
}

__attribute__((visibility("default")))
void m3_trace_intent(unsigned kind, size_t bytes)
{
    if (!phase_ || !kind || !bytes) return;
    pending_kind_ = kind;
    pending_bytes_ = bytes;
    emit('I', 0, bytes, kind);
}

void *malloc(size_t bytes)
{
    void *p = __libc_malloc(bytes);
    if (phase_ && !recording_) {
        unsigned tag = pending_kind_ && pending_bytes_ == bytes
            ? pending_kind_ : 0;
        emit('A', (uintptr_t)p, bytes, tag);
        pending_kind_ = 0; pending_bytes_ = 0;
    }
    return p;
}
void free(void *p)
{
    if (p && phase_ && !recording_) emit('F', (uintptr_t)p, 0, 0);
    __libc_free(p);
}
void *calloc(size_t n, size_t bytes)
{
    void *p = __libc_calloc(n, bytes);
    if (phase_ && !recording_) {
        size_t requested = bytes && n > SIZE_MAX / bytes ? SIZE_MAX : n * bytes;
        emit('A', (uintptr_t)p, requested, 0);
    }
    return p;
}
void *realloc(void *old, size_t bytes)
{
    void *p = __libc_realloc(old, bytes);
    if (phase_ && !recording_ && (p || bytes == 0)) {
        if (old) emit('F', (uintptr_t)old, 0, 0);
        if (p) emit('A', (uintptr_t)p, bytes, 0);
    }
    return p;
}
void *aligned_alloc(size_t alignment, size_t bytes)
{
    if (!alignment || (alignment & (alignment - 1)) || bytes % alignment) {
        errno = EINVAL; return NULL;
    }
    void *p = __libc_memalign(alignment, bytes);
    if (phase_ && !recording_) emit('A', (uintptr_t)p, bytes, 0);
    return p;
}
int posix_memalign(void **out, size_t alignment, size_t bytes)
{
    if (!out || alignment < sizeof(void*) ||
        (alignment & (alignment - 1))) return EINVAL;
    void *p = __libc_memalign(alignment, bytes);
    if (!p) return ENOMEM;
    *out = p;
    if (phase_ && !recording_) emit('A', (uintptr_t)p, bytes, 0);
    return 0;
}
