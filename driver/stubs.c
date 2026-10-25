#include <linux/module.h>
#include <linux/printk.h>
#include <linux/dev_printk.h>

void __brcmf_err(void *bus, const char *func, const char *fmt, ...)
{
	va_list args;
	va_start(args, fmt);
	pr_err("%s: ", func);
	vprintk(fmt, args);
	va_end(args);
}

int brcmf_sdio_register(void) { return 0; }
void brcmf_sdio_exit(void) {}
int brcmf_usb_register(void) { return 0; }
void brcmf_usb_exit(void) {}
