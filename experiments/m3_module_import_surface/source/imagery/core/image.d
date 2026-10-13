/++
    RESEARCH ONLY: typed common-grid image view and checked creation.
    Borrowed raster/validity lifetime rules remain enforced by DIP1000.
+/
module imagery.core.image;

public import m1_5_image_view.contract :
    ImageView, ImageViewValidationError, tryMakeImageView;
