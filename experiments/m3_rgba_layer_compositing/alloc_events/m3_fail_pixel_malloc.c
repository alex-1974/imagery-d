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
static __thread void *packed_pointer_;
static __thread unsigned packed_allocated_;
static __thread unsigned packed_freed_;
static __thread size_t target_import_bytes_;
static __thread unsigned target_import_kind_;

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
    packed_pointer_ = NULL;
    packed_allocated_ = 0;
    packed_freed_ = 0;
    target_import_bytes_ = 0;
    target_import_kind_ = 0;
}

__attribute__((visibility("default")))
void m3_fault_intent(unsigned kind, size_t bytes)
{
    pending_kind_ = kind;
    pending_bytes_ = bytes;
}

/* Kind 3: temporary 1-plane descriptor (24 B on x86-64);
 * Kind 4: retained ResourceEntry metadata (40 B on x86-64).
 * The D consumer arms immediately before the PUBLIC raster import and
 * disarms immediately after it returns. No package(raster) hook is used. */
__attribute__((visibility("default")))
void m3_fault_import_begin(unsigned kind, size_t bytes)
{
    target_import_kind_ = kind;
    target_import_bytes_ = bytes;
}
/* In the new separately compiled owned-result research module the
 * import stage is inside the library, not the caller. Unlike the legacy
 * m3_fault_import_begin, arm this import ONLY for the explicitly selected
 * fault kind; otherwise the two kind checks would overwrite each other.
 * This adds no effect to existing consumer injection calls. */
__attribute__((visibility("default")))
void m3_fault_import_if_armed(unsigned kind, size_t bytes)
{
    if (armed_kind_ == kind)
    {
        target_import_kind_ = kind;
        target_import_bytes_ = bytes;
    }
}

__attribute__((visibility("default")))
void m3_fault_import_end(void)
{
    target_import_kind_ = 0;
    target_import_bytes_ = 0;
}
__attribute__((visibility("default")))
unsigned m3_fault_packed_allocated(void) { return packed_allocated_; }
__attribute__((visibility("default")))
unsigned m3_fault_packed_freed(void) { return packed_freed_; }

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
    if ((kind && intended == bytes && kind == armed_kind_ &&
          bytes == armed_bytes_ && failed_count_ == 0) ||
        (target_import_kind_ && bytes == target_import_bytes_ &&
          failed_count_ == 0))
    {
        failed_count_ = 1;
        failed_kind_ = target_import_kind_
            ? target_import_kind_ : kind;
        armed_kind_ = 0;
        target_import_kind_ = 0;
        errno = ENOMEM;
        return NULL;
    }
    void *result = __libc_malloc(bytes);
    if (kind == 1 && intended == bytes && result != NULL)
    {
        scratch_pointer_ = result;
        ++scratch_allocated_;
    }
    if (kind == 2 && intended == bytes && result != NULL)
    {
        packed_pointer_ = result;
        ++packed_allocated_;
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
    if (p != NULL && p == packed_pointer_)
    {
        ++packed_freed_;
        packed_pointer_ = NULL;
    }
    __libc_free(p);
}
