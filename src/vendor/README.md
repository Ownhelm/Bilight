# ArtPlayer danmuku integration

`artplayer-plugin-danmuku.mjs` is the readable ESM distribution of
`artplayer-plugin-danmuku` 5.3.0 (Harvey Zhao, MIT), copied from the installed npm
package. It stays local because the upstream engine caps travel duration at ten
seconds and starts a separate animation loop for both `play` and `playing`.

Bilight changes: 20/15/10/7.5-second reference speed choices with a ten-second default at 800px;
scrolling duration scales with travel distance to keep CSS-pixel velocity stable
across desktop widths; existing nodes retain their original anchor during resize;
idempotent playback start, including installation during playback; generation checks across asynchronous lane selection;
unique worker request IDs with independent response listeners and cleanup;
correct resize-listener cleanup. The UI and remaining rendering behavior follow
upstream. Types continue to use the npm package. When updating that dependency,
compare this file with its readable ESM distribution and retain these fixes.

The application stylesheet separately exempts opted-in danmaku movement from the
global reduced-motion transition override; other UI keeps reduced motion.

Copyright (c) 2017-2026 Harvey Zhao

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
