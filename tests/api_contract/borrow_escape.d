// MUST fail under DIP1000: a view cannot outlive a local raster owner.
module borrow_escape;
import raster : RasterView, RasterLease;
@safe RasterView!ubyte escapeLocalLease()
{
    RasterLease!ubyte lease;
    return lease.view(); // invalid: borrowed from a local owner
}
