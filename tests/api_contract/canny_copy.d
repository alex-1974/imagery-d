module canny_copy;
import imagery.analysis.canny_worker;
void forbidden(ref CannyWorkspace original) @safe {auto copied=original;}
