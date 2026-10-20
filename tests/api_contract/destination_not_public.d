// MUST NOT compile: the public Levels error set cannot blame a caller
// for an invalid writable destination because callers supply none.
module destination_not_public;
import imagery : LevelsError;

static assert(LevelsError.invalidDestination == LevelsError.allocationFailure);
