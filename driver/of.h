// SPDX-License-Identifier: ISC
/*
 * Copyright (c) 2014 Broadcom Corporation
 */
#if 0
int brcmf_of_probe(struct device *dev, enum brcmf_bus_type bus_type,
		   struct brcmf_mp_device *settings);
#else
static int brcmf_of_probe(struct device *dev, enum brcmf_bus_type bus_type,
			  struct brcmf_mp_device *settings)
{
	return 0;
}
#endif /* CONFIG_OF */
