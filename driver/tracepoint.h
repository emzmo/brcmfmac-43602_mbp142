#ifndef _BRCMF_TRACEPOINT_H_
#define _BRCMF_TRACEPOINT_H_

static inline void trace_brcmf_dbg(int level, const char *fmt, ...) {}
static inline void trace_brcmf_hexdump(void *data, size_t size) {}
static inline void trace_brcmf_bcdchdr(void *h) {}
static inline void trace_brcmf_sdpcm_hdr(int dir, void *h) {}

#endif
