import std.stdio : writeln;
import imagery : openImage;

int main(string[] args)
{
    if (args.length != 2)
        return 2;
    // The generic API detects TIFF from the content signature.
    auto result = openImage(args[1], 3, 2, 7, 6);
    if (!result.ok)
    {
        writeln("imagery imageio consumer failed: ", result.error);
        return 1;
    }
    writeln("imagery imageio consumer: ",
        result.image.region.info.width, "x",
        result.image.region.info.height, " components=",
        result.image.region.info.componentCount, " bytes=",
        result.image.region.data.length);
    return 0;
}
