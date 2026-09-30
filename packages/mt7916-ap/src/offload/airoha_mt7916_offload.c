/*
 * airoha_mt7916_offload.c -- Airoha-AN7581 replacement for the 5.4-era
 * `hw_nat` symbol the MediaTek mt_whnat offload adapter asks for.
 *
 * Background
 * ==========
 * The vendor mt_whnat plug-in ships this declaration only:
 *
 *     extern int (*ra_sw_nat_hook_tx)(struct sk_buff *skb, int gmac_no);
 *
 * and calls it once per unicast TX frame from wifi_tx_tuple_add().  On the
 * Airoha SDK that pointer was filled in by `hw_nat.ko` / `swnat.ko`, which are
 * 5.4.55 modules and unused by ponwrt.
 *
 * ponwrt (6.18) forwards with the mainline stack instead:
 *
 *     nf_flow_table / flow_offload  +  NETIF_F_HWTC  +  airoha_eth PPE
 *
 * so this module owns the symbol and decides what "hand off to the forwarder"
 * means here.
 *
 * Current behaviour: return 0 == "I did not take the packet".  mt_whnat then
 * leaves txblk->DropPkt alone and the frame goes out through the driver's own
 * TX ring, i.e. a correct (if not accelerated) data path.  The ordinary
 * flow-offload machinery in the network stack still learns the flow and can
 * accelerate the ethernet side on its own.
 *
 * TODO (the real binder):
 *   1. look up the airoha npu/eth endpoint referenced by the wifi node's
 *      `airoha,npu` / `airoha,eth` phandles (see an7581.dtsi pcie0 wifi@0,0);
 *   2. claim the WDMA ring for whnat->idx out of the WED descriptors the
 *      already-loaded mt_wifi module owns (hc_get_hif_ctrl() gives the base);
 *   3. push the frame onto that ring and return 1.
 *   Until step 1-3 exist we deliberately stay on the slow path rather than
 *   pretending to offload.
 */

#include <linux/module.h>
#include <linux/skbuff.h>
#include <linux/errno.h>

/*
 * The exact prototype mt_whnat expects.  Keep it in sync with
 * embedded/plug_in/whnat/woe_client_jedi.h.
 */
int (*ra_sw_nat_hook_tx)(struct sk_buff *skb, int gmac_no);
EXPORT_SYMBOL(ra_sw_nat_hook_tx);

/*
 * Slow-path forwarder: refuse ownership.
 *
 * skb           -- unicast frame leaving the AP
 * gmac_no       -- WHNAT_WDMA_PORT (3) as passed by wifi_tx_tuple_add()
 *
 * returns 1: the callee consumed skb, caller must drop its own copy
 *         0: untouched, caller transmits normally
 */
static int airoha_wnat_hook_tx(struct sk_buff *skb, int gmac_no)
{
	return 0;
}

/*
 * Optional: let another module install a real implementation once the NPU
 * binding exists, without rebuilding this one.
 */
void airoha_wnat_hook_tx_set(int (*fn)(struct sk_buff *, int));

void airoha_wnat_hook_tx_set(int (*fn)(struct sk_buff *, int))
{
	ra_sw_nat_hook_tx = fn;
}
EXPORT_SYMBOL(airoha_wnat_hook_tx_set);

static int __init airoha_mt7916_offload_init(void)
{
	ra_sw_nat_hook_tx = airoha_wnat_hook_tx;
	pr_info("airoha_mt7916_offload: ra_sw_nat_hook_tx registered (slow path)\n");
	return 0;
}

static void __exit airoha_mt7916_offload_exit(void)
{
	ra_sw_nat_hook_tx = NULL;
}

module_init(airoha_mt7916_offload_init);
module_exit(airoha_mt7916_offload_exit);

MODULE_DESCRIPTION("AN7581 WiFi-to-Ethernet forwarding endpoint for mt_whnat");
MODULE_LICENSE("Dual BSD/GPL");
