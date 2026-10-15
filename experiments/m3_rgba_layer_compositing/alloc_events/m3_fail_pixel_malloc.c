/* Issue #75: RESEARCH-ONLY deterministic, one-shot glibc malloc failure.
 * LD_PRELOAD this into the independent image consumer, never production.
 * The consumer arms a specific pixel-intent kind/size before its malloc.
 * Only that exactly tagged same-thread request is failed with ENOMEM.
 * Track the actual four-channel scratch address until its real free().
 * Do not infer any allocator usable-size or GC behavior from this.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stddef.h>
#include <stdint.h>

extern void *__libc_malloc(size_t);
extern void __libc_free(void *);

static __thread unsigned armed_kind_;
static __thread size_t armed_bytes_;
static __thread unsigned pending_kind_;
static __thread size_t pending_bytes_;
static __thread unsigned failed_count_;
static __thread unsigned failed_kind_;
static __thread unsigned scratch_allocated_;
static __thread unsigned scratch_freed_;
static __thread void *scratch_pointer_;

__attribute__((visibility("default")))
void m3_fault_arm(unsigned kind, size_t bytes)
{
    armed_kind_ = kind;
    armed_bytes_ = bytes;
    pending_kind_ = 0;
    pending_bytes_ = 0;
    failed_count_ = 0;
    failed_kind_ = 0;
    scratch_allocated_ = 0;
    scratch_freed_ = 0;
    scratch_pointer_ = NULL;
}

__attribute__((visibility("default")))
void m3_fault_intent(unsigned kind, size_t bytes)
{
    pending_kind_ = kind;
    pending_bytes_ = bytes;
}

__attribute__((visibility("default")))
unsigned m3_fault_failed_count(void) { return failed_count_; }
__attribute__((visibility("default")))
unsigned m3_fault_failed_kind(void) { return failed_kind_; }
__attribute__((visibility("default")))
unsigned m3_fault_scratch_allocated(void) { return scratch_allocated_; }
__attribute__((visibility("default")))
unsigned m3_fault_scratch_freed(void) { return scratch_freed_; }

void *malloc(size_t bytes)
{
    const unsigned kind = pending_kind_;
    const size_t intended = pending_bytes_;
    pending_kind_ = 0;
    pending_bytes_ = 0;
    if (kind && intended == bytes && kind == armed_kind_ &&
        bytes == armed_bytes_ && failed_count_ == 0)
    {
        failed_count_ = 1;
        failed_kind_ = kind;
        armed_kind_ = 0;
        errno = ENOMEM;
        return NULL;
    }
    void *result = __libc_malloc(bytes);
    if (kind == 1 && intended == bytes && result != NULL)
    {
        scratch_pointer_ = result;
        ++scratch_allocated_;
    }
    return result;
}

void free(void *p)
{
    if (p != NULL && p == scratch_pointer_)
    {
        ++scratch_freed_;
        scratch_pointer_ = NULL;
    }
    __libc_free(p);
}
