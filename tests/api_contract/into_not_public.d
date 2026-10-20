// MUST fail: the unsafe caller-destination 'Into' API is not exported.
module into_not_public;
import imagery : tryLevelsInto;
void cannotImportInto() {}
