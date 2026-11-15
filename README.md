# Color Extractor

A MAXScript tool for extracting dominant colors from an image and creating an FStormRandomColor map from the resulting palette.

## Usage

1. In 3ds Max, run `ColorExtractor.ms` using **Scripting > Run Script**.
2. Click **Pick image** and select an image.
3. Choose whether to convert the extracted colors to linear values, then click **Extract Colors**.
4. With FStorm set as the current renderer, drag the generated map into a map slot.

The tool displays up to 16 palette colors. The generated FStorm map uses the number of color slots supported by the installed renderer.

## Implementation

The UI uses MAXScript and a .NET PictureBox. An embedded C# helper is compiled at runtime to load thumbnails and extract colors using k-means clustering.

Requires 3ds Max on Windows with the .NET components used by the script. Creating an FStormRandomColor map additionally requires FStorm.

Background color exclusion and weighted clustering are planned; they are not included in the initial version.
