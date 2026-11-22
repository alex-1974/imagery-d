module native_callback_escape;
import imageio : ImageRegion;

alias Consumer=bool delegate(scope const ImageRegion source) @safe;
Consumer escaped;
@safe void retain(scope Consumer consumer)
{
    escaped=consumer;
}
