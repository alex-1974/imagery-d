/++
Split scalar images or masks into regions. Use `floodFill` for one seeded area
or `connectedComponents` for every connected mask region. For full color SLIC,
import `imagery.analysis.color_slic` directly.
+/
module imagery.analysis.segmentation;

public import imagery.analysis.primitives :
    floodFill, connectedComponents, watershed, slic;

