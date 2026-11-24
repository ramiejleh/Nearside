// FFmpeg (LGPL, linked as DLLs). Headers and import libraries come from the FFmpeg build passed
// to swift build: -Xcc -I<ffmpeg>/include -Xlinker -L<ffmpeg>/lib (see windows/Spike/README.md).
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
