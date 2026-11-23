module lazy_path_copy;
import imagery.analysis.cost_path;
struct Costs {double opCall(size_t x,size_t y) @safe nothrow @nogc {return 1;}}
void forbidden(ref LazyCostPath!Costs original) @safe {auto copied=original;}
