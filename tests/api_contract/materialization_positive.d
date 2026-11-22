module materialization_positive;
import imagery.io;
import imagery.materialization;
import imageio : ImageRegion;
import color : Bt601Video;

alias Spec=ValidatedMaterializationSpec!(YCbCrModel!(Bt601Video,0,1,2),
    BilinearUpsampling,LinearFloatOutput!float);

@safe ImageMaterializationError owned(scope ImageRegion image,
    ref OwnedRgbMaterialization!float published)
{
    return tryMaterializeRgbOwned!Spec(image:image,maxResultBytes:1024,published:published);
}

@safe ImageMaterializationError nativeBorrow(scope ImageRegion image)
{
    return visitNativePlanes(image:image,consumer:(scope const ImageRegion source) @safe {
        return source.planes.length!=0 && source.planes[0].data.length!=0;
    });
}

static assert(!ImageMaterializationResult.init.ok && !RgbMaterializationResult!float.init.ok);
