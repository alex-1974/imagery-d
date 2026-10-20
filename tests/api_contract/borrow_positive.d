// Compile-only positive control: DUB paths and DIP1000 are configured.
module borrow_positive;
import raster : RasterLease;
@safe bool localBorrow()
{
    RasterLease!ubyte lease;
    scope auto view = lease.view();
    return view.planeCount == 0;
}
