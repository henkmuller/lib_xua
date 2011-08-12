/**
 * @file    endpoint0.xc
 * @brief   Implements endpoint zero for an USB Audio 1.0/2.0 device
 * @author  Ross Owen, XMOS Semiconductor
 */

#include <xs1.h>
#include <print.h>
#include <safestring.h>

#include "xud.h"                 /* XUD user defines and functions */
#include "usb.h"                 /* Defines from USB 2.0 Spec */
#include "usbaudio20.h"          /* Defines from USB Audio 2.0 spec */

#include "devicedefines.h"
#include "DescriptorRequests.h"  /* This device's descriptors */
#include "descriptors_2.h"       /* Descriptors */
#include "clockcmds.h"
#include "audiostream.h"
#include "vendorrequests.h"
#include "dfu_types.h"

/* Windows does not have a built in DFU driver (windows will prompt), so warn that DFU will not be functional in Audio 1.0 mode.
 * Of course, OSX is unaffected.  
 */
#if ((AUDIO_CLASS==1) || defined(AUDIO_CLASS_FALLBACK)) && defined(DFU)
#warning DFU will require a seperate driver (but will be enabled) in AUDIO 1.0 mode
#endif

/* MIDI not supported in Audio 1.0 mode */
#if ((AUDIO_CLASS==1) || defined(AUDIO_CLASS_FALLBACK)) && defined(MIDI)
#warning MIDI is not supported and will not be enabled in AUDIO 1.0 mode
#endif


#ifndef PID_DFU
#warning PID_DFU not defined, Using PID_AUDIO_2. This is probably fine!
#endif

#ifdef DFU
#include "dfu.h"
#define DFU_IF_NUM INPUT_INTERFACES + OUTPUT_INTERFACES + MIDI_INTERFACES + 1

unsigned int DFU_mode_active = 0;         // 0 - App active, 1 - DFU active
extern void device_reboot(void);
#endif

/* Handles Audio Class requests */
int AudioClassRequests_2(XUD_ep ep0_out, XUD_ep ep0_in, SetupPacket &sp, chanend c_audioControl, chanend ?c_mix_ctl, chanend ?c_clk_ctl);
int AudioClassRequests_1(XUD_ep ep0_out, XUD_ep ep0_in, SetupPacket &sp, chanend c_audioControl, chanend ?c_mix_ctl, chanend ?c_clk_ctl);

/* Global var for current frequency, set to default freq */
unsigned int g_curSamFreq = DEFAULT_FREQ;
unsigned int g_curSamFreq48000Family = DEFAULT_FREQ % 48000 == 0;
unsigned int g_curSamFreqMultiplier = DEFAULT_FREQ / 48000;

/* Global volume and mute tables */ 
int volsOut[NUM_USB_CHAN_OUT + 1];
unsigned int mutesOut[NUM_USB_CHAN_OUT + 1];
//unsigned int multOut[NUM_USB_CHAN_OUT + 1];

int volsIn[NUM_USB_CHAN_IN + 1];
unsigned int mutesIn[NUM_USB_CHAN_IN + 1];
//unsigned int multIn[NUM_USB_CHAN_IN + 1];

#ifdef MIXER
unsigned char mixer1Crossbar[18];
short mixer1Weights[18*8];
//#define MAX_MIX_COUNT 8

unsigned char channelMap[NUM_USB_CHAN_OUT + NUM_USB_CHAN_IN + MAX_MIX_COUNT];
unsigned char channelMapAud[NUM_USB_CHAN_OUT];
unsigned char channelMapUsb[NUM_USB_CHAN_IN];

unsigned char mixSel[MIX_INPUTS];
#endif

int min(int x, int y);

/* Records alt setting for each interface */
int interfaceAlt[NUM_INTERFACES] = {0, 0, 0, 0};

/* Global current device config var*/
unsigned g_config = 0;

/* Global endpoint status arrays */
unsigned g_epStatusOut[NUM_EP_OUT];
unsigned g_epStatusIn[NUM_EP_IN];

/* Global variable for current USB bus speed (i.e. FS/HS) */
unsigned g_curUsbSpeed = 0;

#ifdef HOST_ACTIVE_CALL
void VendorHostActive(int active);
#endif

/* Used when setting/clearing EP halt */
void SetEndpointStatus(unsigned epNum, unsigned status)
{
  /* Inspect for IN bit */
    if( epNum & 0x80 )
    {
        epNum &= 0x7f;

        /* Range check */
        if(epNum < NUM_EP_IN)
        {
            g_epStatusIn[ epNum & 0x7F ] = status;  
        }
    }
    else
    {
        if(epNum < NUM_EP_OUT)
        {
            g_epStatusOut[ epNum ] = status;  
        }
    }
}

#define STR_USENG 0x0409

#define DESC_STR_LANGIDS \
{ \
  STR_USENG & 0xff,               /* 2  wLangID[0] */ \
  STR_USENG>>8,            /* 3  wLangID[0] */ \
  '\0' \
}

/* String descriptors */
static unsigned char strDesc_langIDs[] = DESC_STR_LANGIDS;

void VendorAudioRequestsInit(chanend c_audioControl, chanend ?c_mix_ctl, chanend ?c_clk_ctl);

/* Endpoint 0 function.  Handles all requests to the device */
void Endpoint0( chanend c_ep0_out, chanend c_ep0_in, chanend c_audioControl, chanend ?c_mix_ctl, chanend ?c_clk_ctl
)
{
    unsigned char buffer[512];
    SetupPacket sp;
    XUD_ep ep0_out = XUD_Init_Ep(c_ep0_out);
    XUD_ep ep0_in  = XUD_Init_Ep(c_ep0_in);

    /* Init endpoint status tables */
    for (int i = 0; i++; i < NUM_EP_OUT)
        g_epStatusOut[i] = 0;
    
    for (int i = 0; i++; i < NUM_EP_IN)
        g_epStatusIn[i] = 0;

    /* Init tables for volumes (+ 1 for master) */
    for(int i = 0; i < NUM_USB_CHAN_OUT + 1; i++)
    {
        volsOut[i] = 0;
        mutesOut[i] = 0;
    }

    for(int i = 0; i < NUM_USB_CHAN_IN + 1; i++)
    {
        volsIn[i] = 0;
        mutesIn[i] = 0;
    }

#ifdef MIXER
    /* Set up mixer default state */
    for (int i = 0; i < 18*8; i++) {
      mixer1Weights[i] = 0x8001; //-inf
    }
   
    /* Configure default connections */
    mixer1Weights[0] = 0;
    mixer1Weights[9] = 0;
    mixer1Weights[18] = 0;
    mixer1Weights[27] = 0;
    mixer1Weights[36] = 0;
    mixer1Weights[45] = 0;
    mixer1Weights[54] = 0;
    mixer1Weights[63] = 0;

    /* Setup up audio output channel mapping */
    for(int i = 0; i < NUM_USB_CHAN_OUT; i++)
    {
       channelMapAud[i] = i; 
    }

    for(int i = 0; i < NUM_USB_CHAN_IN; i++)
    {
       channelMapUsb[i] = i + NUM_USB_CHAN_OUT; 
    }


    /* Set up channel mapping default */
    for (int i = 0; i < NUM_USB_CHAN_OUT + NUM_USB_CHAN_IN; i++) 
    {
        channelMap[i] = i;
    }

#if MAX_MIX_COUNT > 0
    /* Mixer outputs mapping defaults */
    for (int i = 0; i < MAX_MIX_COUNT; i++) 
    {
        channelMap[NUM_USB_CHAN_OUT + NUM_USB_CHAN_IN + i] = i;
    }
#endif

    /* Init mixer inputs */
    for(int i = 0; i < MIX_INPUTS; i++)
    {
        mixSel[i] = i;
    }
#endif

    /* Copy langIDs string desc into string[0] */
    /* TODO: Macro? */
#if defined(AUDIO_CLASS_FALLBACK) || (AUDIO_CLASS == 1) 
    safememcpy(strDescs_Audio1[0], strDesc_langIDs, sizeof(strDesc_langIDs));
#endif
    safememcpy(strDescs_Audio2[0], strDesc_langIDs, sizeof(strDesc_langIDs));

    /* Build up channel string table - By default all channels are marked as analogue
     * TODO We really want to do this an build time... */
#if defined(SPDIF_RX) && (SPDIF_RX_INDEX != 0)
    safestrcpy(strDescs_Audio2[SPDIF_RX_INDEX + 31], "S/PDIF 1");
    safestrcpy(strDescs_Audio2[SPDIF_RX_INDEX + 32], "S/PDIF 2");
#endif
#if defined(ADAT_RX) && (ADAT_RX_INDEX != 0)
    safestrcpy(strDescs_Audio2[ADAT_RX_INDEX + 31], "ADAT 1");
    safestrcpy(strDescs_Audio2[ADAT_RX_INDEX + 32], "ADAT 2");
    safestrcpy(strDescs_Audio2[ADAT_RX_INDEX + 33], "ADAT 3");
    safestrcpy(strDescs_Audio2[ADAT_RX_INDEX + 34], "ADAT 4");
    safestrcpy(strDescs_Audio2[ADAT_RX_INDEX + 35], "ADAT 5");
    safestrcpy(strDescs_Audio2[ADAT_RX_INDEX + 36], "ADAT 6");
    safestrcpy(strDescs_Audio2[ADAT_RX_INDEX + 37], "ADAT 7");
    safestrcpy(strDescs_Audio2[ADAT_RX_INDEX + 38], "ADAT 8");
#endif

#if defined(SPDIF) && (SPDIF_TX_INDEX != 0)     /* "Analogue naming gets priority */ 
    safestrcpy(strDescs_Audio2[SPDIF_TX_INDEX + 13], "S/PDIF 1");
    safestrcpy(strDescs_Audio2[SPDIF_TX_INDEX + 14], "S/PDIF 2");
#endif
#if defined(ADAT_TX) && (ADAT_TX_INDEX != 0)
    safestrcpy(strDescs_Audio2[ADAT_TX_INDEX + 13], "ADAT 1");
    safestrcpy(strDescs_Audio2[ADAT_TX_INDEX + 14], "ADAT 2");
    safestrcpy(strDescs_Audio2[ADAT_TX_INDEX + 15], "ADAT 3");
    safestrcpy(strDescs_Audio2[ADAT_TX_INDEX + 16], "ADAT 4");
    safestrcpy(strDescs_Audio2[ADAT_TX_INDEX + 17], "ADAT 5");
    safestrcpy(strDescs_Audio2[ADAT_TX_INDEX + 18], "ADAT 6");
    safestrcpy(strDescs_Audio2[ADAT_TX_INDEX + 19], "ADAT 7");
    safestrcpy(strDescs_Audio2[ADAT_TX_INDEX + 20], "ADAT 8");
#endif

#ifdef VENDOR_AUDIO_REQS
    VendorAudioRequestsInit(c_audioControl, c_mix_ctl, c_clk_ctl);
#endif

#ifdef DFU
    /* Check if device has started in DFU mode */
    if (DFUReportResetState(null)) 
    {
        /* Stop audio */
        outuint(c_audioControl, SET_SAMPLE_FREQ);
        outuint(c_audioControl, AUDIO_STOP_FOR_DFU);
        // No Handshake
        //chkct(c_audioControl, XS1_CT_END);
        DFU_mode_active = 1;
    } 
#endif
    
    while(1)
    {
        int retVal = 1;
     
        /* Do standard enumeration requests */
#ifndef DFU
        if(g_curUsbSpeed == XUD_SPEED_HS)
        {

#ifdef AUDIO_CLASS_FALLBACK
            /* Return Audio 2.0 Descriptors with Audio 1.0 as fallback */
            cfgDesc_Audio2[1] = CONFIGURATION;
            cfgDesc_Audio1[1] = OTHER_SPEED_CONFIGURATION;
        
            retVal = DescriptorRequests(ep0_out, ep0_in, 
                devDesc_Audio2, sizeof(devDesc_Audio2), 
                cfgDesc_Audio2, sizeof(cfgDesc_Audio2), 
                devQualDesc_Audio1, sizeof(devQualDesc_Audio1), 
                cfgDesc_Audio1, sizeof(cfgDesc_Audio1), 
                strDescs_Audio2, sp);
#else
            /* Return Audio 2.0 Descriptors */
            cfgDesc_Audio2[1] = CONFIGURATION;
            cfgDesc_Null[1] = OTHER_SPEED_CONFIGURATION;
        
            retVal = DescriptorRequests(ep0_out, ep0_in, 
                devDesc_Audio2, sizeof(devDesc_Audio2), 
                cfgDesc_Audio2, sizeof(cfgDesc_Audio2), 
                devQualDesc_Null, sizeof(devQualDesc_Null), 
                cfgDesc_Null, sizeof(cfgDesc_Null), 
                strDescs_Audio2, sp);
#endif
        }
        else
        {
            /* Return descriptors for full-speed - Audio 1.0? */
#ifdef AUDIO_CLASS_FALLBACK
            cfgDesc_Audio1[1] = CONFIGURATION;
            cfgDesc_Audio2[1] = OTHER_SPEED_CONFIGURATION;
            
            retVal = DescriptorRequests(ep0_out, ep0_in, 
                devDesc_Audio1, sizeof(devDesc_Audio1), 
                cfgDesc_Audio1, sizeof(cfgDesc_Audio1), 
                devQualDesc_Audio2, sizeof(devQualDesc_Audio2), 
                cfgDesc_Audio2, sizeof(cfgDesc_Audio2), 
                strDescs_Audio1, sp);

#else
            cfgDesc_Null[1] = CONFIGURATION;
            cfgDesc_Audio2[1] = OTHER_SPEED_CONFIGURATION;
            
            retVal = DescriptorRequests(ep0_out, ep0_in, 
                devDesc_Null, sizeof(devDesc_Null), 
                cfgDesc_Null, sizeof(cfgDesc_Null), 
                devQualDesc_Audio2, sizeof(devQualDesc_Audio2), 
                cfgDesc_Audio2, sizeof(cfgDesc_Audio2), 
                strDescs_Audio2, sp);
#endif 

        }
#else /* ifndef DFU */
        if (!DFU_mode_active) 
        {
            if(g_curUsbSpeed == XUD_SPEED_HS)
            {

#ifdef AUDIO_CLASS_FALLBACK
                /* Return Audio 2.0 Descriptors with Audio 1.0 as fallback */
                cfgDesc_Audio2[1] = CONFIGURATION;
                cfgDesc_Audio1[1] = OTHER_SPEED_CONFIGURATION;
        
                retVal = DescriptorRequests(ep0_out, ep0_in, 
                    devDesc_Audio2, sizeof(devDesc_Audio2), 
                    cfgDesc_Audio2, sizeof(cfgDesc_Audio2), 
                    devQualDesc_Audio1, sizeof(devQualDesc_Audio1), 
                    cfgDesc_Audio1, sizeof(cfgDesc_Audio1), 
                    strDescs_Audio2, sp);
#else
                /* Return Audio 2.0 Descriptors with Null device as fallback */
                cfgDesc_Audio2[1] = CONFIGURATION;
                cfgDesc_Null[1] = OTHER_SPEED_CONFIGURATION;
        
                retVal = DescriptorRequests(ep0_out, ep0_in, 
                    devDesc_Audio2, sizeof(devDesc_Audio2), 
                    cfgDesc_Audio2, sizeof(cfgDesc_Audio2), 
                    devQualDesc_Null, sizeof(devQualDesc_Null), 
                    cfgDesc_Null, sizeof(cfgDesc_Null), 
                    strDescs_Audio2, sp);
#endif

            }
            else
            {
                /* Return descriptors for full-speed - Audio 1.0? */
#ifdef AUDIO_CLASS_FALLBACK 
                cfgDesc_Audio1[1] = CONFIGURATION;
                cfgDesc_Audio2[1] = OTHER_SPEED_CONFIGURATION;
            
                retVal = DescriptorRequests(ep0_out, ep0_in, 
                    devDesc_Audio1, sizeof(devDesc_Audio1), 
                    cfgDesc_Audio1, sizeof(cfgDesc_Audio1), 
                    devQualDesc_Audio2, sizeof(devQualDesc_Audio2), 
                    cfgDesc_Audio2, sizeof(cfgDesc_Audio2), 
                    strDescs_Audio1, sp);
#else
                cfgDesc_Null[1] = CONFIGURATION;
                cfgDesc_Audio2[1] = OTHER_SPEED_CONFIGURATION;
            
                retVal = DescriptorRequests(ep0_out, ep0_in, 
                    devDesc_Null, sizeof(devDesc_Null), 
                    cfgDesc_Null, sizeof(cfgDesc_Null), 
                    devQualDesc_Audio2, sizeof(devQualDesc_Audio2), 
                    cfgDesc_Audio2, sizeof(cfgDesc_Audio2), 
                    strDescs_Audio2, sp);
#endif 

            }
        } 
        else 
        {
            /* Running in DFU mode - always return same descs for DFU whether HS or FS */
            retVal = DescriptorRequests(ep0_out, ep0_in, 
                DFUdevDesc, sizeof(DFUdevDesc), 
                DFUcfgDesc, sizeof(DFUcfgDesc), 
                DFUdevQualDesc, sizeof(DFUdevQualDesc), 
                DFUoSpeedCfgDesc, sizeof(DFUoSpeedCfgDesc), 
                strDescs_Audio2, sp);
        }
#endif
        
        if (retVal == 1)
        {
            /* Request not covered by XUD_DoEnumReqs() so decode ourselves */
            /* Inspect Request type and Receipient */ 
            switch( (sp.bmRequestType.Recipient ) | (sp.bmRequestType.Type << 5) )
            {
                case STANDARD_INTERFACE_REQUEST:
                    
                    switch(sp.bRequest)
                    {
                        /* Set Interface */
                        case SET_INTERFACE:


#if defined(OUTPUT) && defined(INPUT)
                            /* Check for stream start stop on output and input audio interfaces */
                            if(sp.wValue && !interfaceAlt[1] && !interfaceAlt[2])
                            {
                                /* If start and input AND output not currently running */
                                AudioStreamStart();
                            }
                            else if(((sp.wIndex == 1)&& (!sp.wValue)) && interfaceAlt[1] && (!interfaceAlt[2]))
                            {
                                /* if output stop and output running and input not running */
                                AudioStreamStop();
                            }
                            else if(((sp.wIndex == 2) && (!sp.wValue)) && interfaceAlt[2] && (!interfaceAlt[1]))
                            {
                                /* if input stop and input running and output not running */
                                AudioStreamStop();
                            }
#elif defined(OUTPUT) || defined(INPUT)
                            if(sp.wValue && (!interfaceAlt[1]))
                            {
                                /* if start and not currently running */
                                AudioStreamStart();
                            }
                            else if (!sp.wValue && interfaceAlt[1])
                            {
                                /* if stop and currently running */
                                AudioStreamStop();
                            }

#endif
                            /* Record interface change */
                            if( sp.wIndex < NUM_INTERFACES )
                                interfaceAlt[sp.wIndex] = sp.wValue;
#if 1
                            /* Check for audio stream from host start/stop */
                            if(sp.wIndex == 2) // Input interface
                            {
                                switch(sp.wValue)
                                {
                                    case 0:
                                       
                                        break;

                                    case 1:
                                        /* Stream active + 0 chans */
                                        outuint(c_audioControl, SET_CHAN_COUNT_IN);
                                        outuint(c_audioControl, NUM_USB_CHAN_IN);
                                        
#ifdef ADAT_RX 
                                        outuint(c_clk_ctl, SET_SMUX);
                                        outuint(c_clk_ctl, 0); 
                                        outct(c_clk_ctl, XS1_CT_END);
#endif

                                          break;
        
#ifdef ADAT_RX                                                                        
                                     case 2:
                                        
                                        /* Stream active + 8 chans */
                                        outuint(c_audioControl, SET_CHAN_COUNT_IN);
                                        outuint(c_audioControl, NUM_USB_CHAN_IN-4);

                                        outuint(c_clk_ctl, SET_SMUX);
                                        outuint(c_clk_ctl, 1); 
                                        outct(c_clk_ctl, XS1_CT_END);
                                        break;

                                    case 3:
                                        outuint(c_audioControl, SET_CHAN_COUNT_IN);
                                        outuint(c_audioControl, NUM_USB_CHAN_IN-6);


                                        outuint(c_clk_ctl, SET_SMUX);
                                        outuint(c_clk_ctl, 1); 
                                        outct(c_clk_ctl, XS1_CT_END);
                                        /* Stream active + 8 chans */
                                        //outuint(c_audioControl, 8);
                                        // Handshake
                                        //chkct(c_audioControl, XS1_CT_END);

                                        //printint(8);
                                        break;

#endif

                                }              
                            }
#endif
                            /* No data stage for this request, just do data stage */
                            retVal = XUD_DoSetRequestStatus(ep0_in, 0);
                            break;

                        /* A device must support the GetInterface request if it has alternate setting for that interface */
                        case GET_INTERFACE: 
                            
                            buffer[0] = 0;

                            /* Bounds check */
                            if( sp.wIndex < NUM_INTERFACES )
                                buffer[0] = interfaceAlt[sp.wIndex];

                            retVal = XUD_DoGetRequest(ep0_out, ep0_in,  buffer, 1, sp.wLength);
                            break;
            

                        default:
                                printstr("Unknown Standard Interface Request: ");
                                printhexln(sp.bRequest);
                                printhexln(sp.bmRequestType.Type);
                                printhexln(sp.bmRequestType.Recipient);
                                printhexln(sp.bmRequestType.Recipient | (sp.bmRequestType.Type << 5));
                                break;
                   }
                   break;
            
                /* Recipient: Device */
                case STANDARD_DEVICE_REQUEST:
                            
                    /* Standard Device requests (8) */
                    switch( sp.bRequest )
                    {      
                        
                        /* Set Device Address: This is a unique set request. */
                        case SET_ADDRESS:
            
                            /* Status stage: Send a zero length packet */
                            retVal = XUD_SetBuffer_ResetPid(ep0_in,  buffer, 0, PIDn_DATA1);

                            /* TODO We should wait until ACK is received for status stage before changing address */
                            //XUD_Sup_Delay(50000);
                            {
                                timer t;
                                unsigned time;
                                t :> time;
                                t when timerafter(time+50000) :> void;
                            }

                            /* Set device address in XUD */
                            XUD_SetDevAddr(sp.wValue);

                            break;

                        
                        /* TODO Check direction */
                        /* Standard request: SetConfiguration */
                        case SET_CONFIGURATION:
                
                            g_config = sp.wValue;

#ifdef HOST_ACTIVE_CALL
                            if(g_config == 1)
                            {
                                /* Consider host active with valid driver at this point */
                                VendorHostActive(1);
                            }
#endif

                            /* No data stage for this request, just do status stage */
                            retVal = XUD_DoSetRequestStatus(ep0_in, 0);
                            break;

                        case GET_CONFIGURATION:
                            buffer[0] = g_config;
                            retVal = XUD_DoGetRequest(ep0_out, ep0_in, buffer, 1, sp.wLength);
                           break; 

                        /* Get Status request */
                        case GET_STATUS:

                            buffer[0] = 0; // bus powered
                            buffer[1] = 0; // remote wakeup not supported
                            
                            retVal = XUD_DoGetRequest(ep0_out, ep0_in, buffer,  2, sp.wLength);
                            break;


                        default:
                           XUD_Error("Unknown device request");
                            break;
          
                    }  
                    break;
         
                /* Receipient: Endpoint */
                case STANDARD_ENDPOINT_REQUEST:
                             
                     /* Standard endpoint requests */
                     switch ( sp.bRequest )
                     {
                         
                        /* ClearFeature */
                        case CLEAR_FEATURE:
                
                            switch ( sp.wValue )
                            {
                                case ENDPOINT_HALT:
                                    
                                    /* Mark the endpoint status */

                                    SetEndpointStatus(sp.wIndex, 0);

                                    /* No data stage for this request, just do status stage */
                                    retVal = XUD_DoSetRequestStatus(ep0_in, 0);

                                    break;

                                
                                default:
                                    XUD_Error( "Unknown request in Endpoint ClearFeature" );
                                    break;
                            }
                            break; /* B_REQ_CLRFEAR */

                        /* SetFeature */
                        case SET_FEATURE:

                            switch( sp.wValue )  
                            {
                                case ENDPOINT_HALT:
                                    
                                    /* Check request is in range */
                                    SetEndpointStatus(sp.wIndex, 1);
                                
                                    break;
                                
                                default:
                                    XUD_Error("Unknown feature in SetFeature Request");
                                    break;
                            }


                            retVal = XUD_DoSetRequestStatus(ep0_in, 0);

                            break;


   
                        /* Endpoint GetStatus Request */
                        case GET_STATUS:

                            buffer[0] = 0;
                            buffer[1] = 0;

                            if( sp.wIndex & 0x80 )
                            {
                                /* IN Endpoint */
                                if((sp.wIndex&0x7f) < NUM_EP_IN)
                                {
                                    buffer[0] = ( g_epStatusIn[ sp.wIndex & 0x7F ] & 0xff );
                                    buffer[1] = ( g_epStatusIn[ sp.wIndex & 0x7F ] >> 8 );
                                }
                            }
                            else
                            {
                                /* OUT Endpoint */
                                if(sp.wIndex < NUM_EP_OUT)
                                {
                                    buffer[0] = ( g_epStatusOut[ sp.wIndex ] & 0xff );
                                    buffer[1] = ( g_epStatusOut[ sp.wIndex ] >> 8 );
                                }
                            }
                                   
                            retVal = XUD_DoGetRequest(ep0_out, ep0_in, buffer,  2, sp.wLength);
                        
                        break;

                        default:
                            //printstrln("Unknown Standard Endpoint Request");   
                            break;

                    }
                    break;
          
                case CLASS_INTERFACE_REQUEST:         
				case CLASS_ENDPOINT_REQUEST: 
                {
                    unsigned interfaceNum = sp.wIndex & 0xff;
					unsigned request = (sp.bmRequestType.Recipient ) | (sp.bmRequestType.Type << 5);

                    /* TODO Check interface number */
                    /* TODO Check on return value retval =  */
#ifdef DFU
                    unsigned DFU_IF = DFU_IF_NUM;

                    /* DFU interface number changes based on which mode we are currently running in */
                    if (DFU_mode_active) 
                    {
                        DFU_IF = 0;
                    }

                    if (interfaceNum == DFU_IF) 
                    {

                        /* If running in application mode stop audio */
                        /* Don't interupt audio for save and restore cmds */
                        if ((DFU_IF == DFU_IF_NUM) && (sp.bRequest != XMOS_DFU_SAVESTATE) && (sp.bRequest != XMOS_DFU_RESTORESTATE))
                        {
                            // Stop audio
                            outuint(c_audioControl, SET_SAMPLE_FREQ);
                            outuint(c_audioControl, AUDIO_STOP_FOR_DFU);
                            // Handshake
							chkct(c_audioControl, XS1_CT_END);
							
                        }
                     
					  
                        /* This will return 1 if reset requested */
                        if (DFUDeviceRequests(ep0_out, ep0_in, sp, null, interfaceAlt[sp.wIndex], 1)) 
                        {
                            timer tmr;
                            unsigned s;
                            /* Send reboot command */
                            //outuint(c_audioControl, SET_SAMPLE_FREQ);
                            //outuint(c_audioControl, AUDIO_REBOOT_FROM_DFU);
                            tmr :> s;
                            tmr when timerafter(s + 50000000) :> s;
                            device_reboot();
                        }

                        /* TODO we should not make the assumtion that all DFU requests are handled */
                        retVal = 0;
                    } 
                    /* Check for:   Audio interface request - always 0, note we check for DFU first 
                     *              Audio endpoint request */
                    else if(((request == CLASS_INTERFACE_REQUEST) && (interfaceNum == 0)) 
                        || (request == CLASS_ENDPOINT_REQUEST && ((interfaceNum == 0x82) || (interfaceNum == 0x01)))) 
				    {
#endif
#if (AUDIO_CLASS == 2) && defined(AUDIO_CLASS_FALLBACK)
                        if(g_curUsbSpeed == XUD_SPEED_HS)
                        {
                            retVal = AudioClassRequests_2(ep0_out, ep0_in, sp, c_audioControl, c_mix_ctl, c_clk_ctl);
                        }
                        else
                        {
                            retVal = AudioClassRequests_1(ep0_out, ep0_in, sp, c_audioControl, c_mix_ctl, c_clk_ctl);
                        }
#elif (AUDIO_CLASS==2)
                        retVal = AudioClassRequests_2(ep0_out, ep0_in, sp, c_audioControl, c_mix_ctl, c_clk_ctl);
#else
                        retVal = AudioClassRequests_1(ep0_out, ep0_in, sp, c_audioControl, c_mix_ctl, c_clk_ctl);
#endif

#ifdef VENDOR_AUDIO_REQS
                        /* If retVal is 1 at this point, then request to audio interface not handled - handle vendor audio reqs */
                        if(retVal == 1)
                        {
                            retVal = VendorAudioRequests(ep0_out, ep0_in, sp.bRequest,
                            	sp.wValue >> 8, sp.wValue & 0xff,
                            	sp.wIndex >> 8, sp.bmRequestType.Direction,
                            	c_audioControl, c_mix_ctl, c_clk_ctl); 
                        }
#endif
#ifdef DFU
                    }
#endif
                }
                    break;
                
                default:
                    // TODO: STALL
                    //printstr("unrecognised request\n");
                    //printhexln(sp.bRequest);
                    //printhexln(sp.bmRequestType.Type);
                    //printhexln(sp.bmRequestType.Recipient);
                    //printhexln(sp.bmRequestType.Recipient | (sp.bmRequestType.Type << 5));
                    break;
                    
                 
            }
                  
        } /* if(retVal == 0) */
     
        if(retVal == 1)
        {
            /* Did not handle request - Protocol Stall Secion 8.4.5 of USB 2.0 spec 
             * Detailed in Section 8.5.3. Protocol stall is unique to control pipes. 
               Protocol stall differs from functional stall in meaning and duration. 
               A protocol STALL is returned during the Data or Status stage of a control 
               transfer, and the STALL condition terminates at the beginning of the 
               next control transfer (Setup). The remainder of this section refers to 
               the general case of a functional stall */
            //XUD_ProtocolStall(ep0_out, ep0_in):
        } 
        
        if (retVal < 0) 
        {
            g_curUsbSpeed = XUD_ResetEndpoint(ep0_in, ep0_out);

            g_config = 0;

#ifdef DFU
            if (DFUReportResetState(null)) 
            {
                if (!DFU_mode_active) 
                {
                    timer tmr;
                    unsigned s;
                    DFU_mode_active = 1;
                    //tmr :> s;
                    //tmr when timerafter(s + 500000) :> s;
                }
            } 
            else 
            {
                if (DFU_mode_active) 
                {
                    timer tmr;
                    unsigned s;
                    // Restart audio
                    //outuint(c_audioControl, AUDIO_START_FROM_DFU);
                    DFU_mode_active = 0;
                    // Send reboot command
                    //outuint(c_audioControl, SET_SAMPLE_FREQ);
                    //outuint(c_audioControl, AUDIO_REBOOT_FROM_DFU);
                    // No handshake on reboot
                    tmr :> s;
                    tmr when timerafter(s + 5000000) :> s;
                    device_reboot();
                }
            }
#endif
        }

    }
}