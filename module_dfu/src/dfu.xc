#include <xs1.h>
#include <platform.h>
#include <print.h>

#include "xud.h"
#ifdef ARCH_G
#include "XUD_USB_Defines.h"
#else
#include "usb.h"
#endif

#include "dfu_types.h"
#include "flash_programmer.h"

static int DFU_state = STATE_APP_IDLE;
static int DFU_status = DFU_OK;
static timer DFUTimer;
static unsigned int DFUTimerStart = 0;
static unsigned int DFUResetTimeout = 100000000; // 1 second default
static int DFU_flash_connected = 0;

static unsigned int subPagesLeft = 0;

extern int DFU_reset_override;

void temp() {
 asm(".linkset DFU_reset_override, _edp.bss");
 asm(".globl DFU_reset_override");
}

static int DFU_OpenFlash(chanend ?c_user_cmd) 
{
	if (!DFU_flash_connected) 
	{
    	unsigned int cmd_data[16];
    	HandleUserDeviceRequest(FLASH_CMD_INIT, 1, 0, cmd_data, c_user_cmd);
    	DFU_flash_connected = 1;
  	}
  
  	return 0;
}

static int DFU_CloseFlash(chanend ?c_user_cmd) {
  if (DFU_flash_connected) {
    unsigned int cmd_data[16];
    HandleUserDeviceRequest(FLASH_CMD_DEINIT, 1, 0, cmd_data, c_user_cmd);
    DFU_flash_connected = 0;
  }
  return 0;
}

static int DFU_Detach(unsigned int timeout, chanend ?c_user_cmd) {
  if (DFU_state == STATE_APP_IDLE) {

    DFU_state = STATE_APP_DETACH;

    DFU_OpenFlash(c_user_cmd);

    // Setup DFU timeout value
    DFUResetTimeout = timeout * 100000;
    
    // Start DFU reset timer
    DFUTimer :> DFUTimerStart;
  } else {
    DFU_state = STATE_DFU_ERROR;
  }
  return 0; 
}

static int DFU_Dnload(unsigned int request_len, unsigned int block_num, unsigned int request_data[16], chanend ?c_user_cmd) {
  unsigned int fromDfuIdle = 0;

  // Get DFU packets here, sequence is
  // DFU_DOWNLOAD -> DFU_DOWNLOAD_SYNC
  // GET_STATUS -> DFU_DOWNLOAD_SYNC (flash busy) || DFU_DOWNLOAD_IDLE
  // REPEAT UNTIL DFU_DOWNLOAD with 0 length -> DFU_MANIFEST_SYNC

  DFU_OpenFlash(c_user_cmd);

  switch (DFU_state) {
    case STATE_DFU_IDLE:
    case STATE_DFU_DOWNLOAD_IDLE:
      break;
    default:
      DFU_state = STATE_DFU_ERROR;
      return 0;
  }

  if ((DFU_state == STATE_DFU_IDLE) && (request_len == 0)) {
    DFU_state = STATE_DFU_ERROR;
    return 0;
  } else if (DFU_state == STATE_DFU_IDLE) {
    fromDfuIdle = 1;
  } else {
    fromDfuIdle = 0;
  }

  if (request_len == 0) {
    // Host signalling complete download
    int i = 0;
    unsigned int cmd_data[16];
    if (subPagesLeft) {
      unsigned int subPagePad[16] = {0};
      for (i = 0; i < subPagesLeft; i++) {
        HandleUserDeviceRequest(FLASH_CMD_WRITE_PAGE_DATA, 1, 64, subPagePad, c_user_cmd);
      }
    }

    cmd_data[0] = 2; // Terminate write
    HandleUserDeviceRequest(FLASH_CMD_WRITE_PAGE, 1, 4, cmd_data, c_user_cmd);

    DFU_state = STATE_DFU_MANIFEST_SYNC;
  } else {
    unsigned int i = 0;
    unsigned int flash_cmd = 0;
    unsigned int flash_page_index = 0;
    unsigned int cmd_data[16];
    
    if (fromDfuIdle) 
    { 
      unsigned s = 0;

#if 0
      /* Flash lib does erase on add image */
      // Erase flash on first block
      HandleUserDeviceRequest(FLASH_CMD_ERASE_ALL, 1, 0, cmd_data, c_user_cmd);
#endif

#if 0
      /* Delay should not be required.  Erase now blocking call */
      DFUTimer :> s;
      DFUTimer when timerafter(s + 25000000) :> s; // Wait for flash erase
#endif   
    }

    // Program firmware, STATE_DFU_DOWNLOAD_BUSY not currently used

    if (!(block_num % 4)) {
      cmd_data[0] = !fromDfuIdle; // 0 for first page, 1 for other pages.
      HandleUserDeviceRequest(FLASH_CMD_WRITE_PAGE, 1, 4, cmd_data, c_user_cmd);
      subPagesLeft = 4;
    }
 
    for (i = 0; i < 16; i++) {
      cmd_data[i] = request_data[i];
    }

    HandleUserDeviceRequest(FLASH_CMD_WRITE_PAGE_DATA, 1, 64, cmd_data, c_user_cmd);
    subPagesLeft--;

    DFU_state = STATE_DFU_DOWNLOAD_SYNC;
  }

  return 0; 
}


static int DFU_Upload(unsigned int request_len, unsigned int block_num, unsigned int request_data[16], chanend ?c_user_cmd) {
  unsigned int cmd_data[16];
  unsigned int firstRead = 0;

  // Start at flash address 0
  // Keep reading flash pages until read_page returns 1 (address out of range)
  // Return terminating upload packet at this point
 
  DFU_OpenFlash(c_user_cmd);
 
  switch (DFU_state) {
    case STATE_DFU_IDLE:
    case STATE_DFU_UPLOAD_IDLE:
      break;
    default:
      DFU_state = STATE_DFU_ERROR;
      return 0;
  }

  //printintln(request_len);

  if ((DFU_state == STATE_DFU_IDLE) && (request_len == 0)) {
    DFU_state = STATE_DFU_ERROR;
    return 0;
  } else if (DFU_state == STATE_DFU_IDLE) {
    firstRead = 1;
    subPagesLeft = 0;
  }

  if (!subPagesLeft) {
    cmd_data[0] = !firstRead;

    // Read page
    HandleUserDeviceRequest(FLASH_CMD_READ_PAGE, 0, 4, cmd_data, c_user_cmd);
    subPagesLeft = 4;

    // If address out of range, terminate!
    if (cmd_data[0] == 1) {
      subPagesLeft = 0;
      // Back to idle state, upload complete
      DFU_state = STATE_DFU_IDLE;
      return 0;
    }
  }  

  // Read page data
  HandleUserDeviceRequest(FLASH_CMD_READ_PAGE_DATA, 0, 0, request_data, c_user_cmd);

  subPagesLeft--;

  DFU_state = STATE_DFU_UPLOAD_IDLE;

  return 64; 
}

static int DFU_GetStatus(unsigned int request_len, unsigned int request_data[16], chanend ?c_user_cmd) {
  unsigned int timeout = 0;

  request_data[0] = timeout << 8 | (unsigned char)DFU_status;
 
  switch (DFU_state) {
    case STATE_DFU_MANIFEST:
    case STATE_DFU_MANIFEST_WAIT_RESET:
      DFU_state = STATE_DFU_ERROR;
      break;
    case STATE_DFU_DOWNLOAD_BUSY:
      // If download completes -> DFU_DOWNLOAD_SYNC
      // Currently all transactions are synchronous so no busy state
      break;
    case STATE_DFU_DOWNLOAD_SYNC:
      DFU_state = STATE_DFU_DOWNLOAD_IDLE;
      break;
    case STATE_DFU_MANIFEST_SYNC:
      // Check if complete here
      DFU_state = STATE_DFU_IDLE;
      break;
    default:
      break;
  }

  request_data[1] = DFU_state;

  return 6; 
}

static int DFU_ClrStatus(void) {
  if (DFU_state == STATE_DFU_ERROR) {
    DFU_state = STATE_DFU_IDLE;
  } else {
    DFU_state = STATE_DFU_ERROR;
  }
  return 0; 
}

static int DFU_GetState(unsigned int request_len, unsigned int request_data[16], chanend ?c_user_cmd) {

  request_data[0] = DFU_state;

  switch (DFU_state) {
    case STATE_DFU_DOWNLOAD_BUSY:
    case STATE_DFU_MANIFEST:
    case STATE_DFU_MANIFEST_WAIT_RESET:
      DFU_state = STATE_DFU_ERROR;
      break;
    default:
      break;
  }

  return 1; 
}

static int DFU_Abort(void) {
  DFU_state = STATE_DFU_IDLE;
  return 0; 
}

// Tell the DFU state machine that a USB reset has occured
int DFUReportResetState(chanend ?c_user_cmd) {
  unsigned int inDFU = 0;
  unsigned int currentTime = 0;

  if (DFU_reset_override == 0x11042011) {
    unsigned int cmd_data[16];
    inDFU = 1;
    DFU_state = STATE_DFU_IDLE;
    return inDFU;
  }

  switch(DFU_state) {
    case STATE_APP_DETACH:
    case STATE_DFU_IDLE:
      DFU_state = STATE_DFU_IDLE;

      DFUTimer :> currentTime;
      if (currentTime - DFUTimerStart > DFUResetTimeout) {
        DFU_state = STATE_APP_IDLE;
        //printintln(currentTime - DFUTimerStart);
        //printintln(DFUResetTimeout);
        inDFU = 0;
      } else {
        inDFU = 1;
      }
      break;
    case STATE_APP_IDLE:
    case STATE_DFU_DOWNLOAD_SYNC:
    case STATE_DFU_DOWNLOAD_BUSY:
    case STATE_DFU_DOWNLOAD_IDLE:
    case STATE_DFU_MANIFEST_SYNC:
    case STATE_DFU_MANIFEST:
    case STATE_DFU_MANIFEST_WAIT_RESET:
    case STATE_DFU_UPLOAD_IDLE:
    case STATE_DFU_ERROR:
      inDFU = 0;
      DFU_state = STATE_APP_IDLE;
      break;
    default: 
      DFU_state = STATE_DFU_ERROR;
      inDFU = 1;
      break;
  }

  if (!inDFU) {
    DFU_CloseFlash(c_user_cmd);
  }

  return inDFU;
}

int XMOS_DFU_RevertFactory(chanend ?c_user_cmd) {
  unsigned int cmd_data[16];
  unsigned s = 0;

  DFU_OpenFlash(c_user_cmd);

  HandleUserDeviceRequest(FLASH_CMD_ERASE_ALL, 1, 0, cmd_data, c_user_cmd);

  DFUTimer :> s;
  DFUTimer when timerafter(s + 25000000) :> s; // Wait for flash erase
  
  return 0;
}

int XMOS_DFU_SelectImage(unsigned int index, chanend ?c_user_cmd) {

  // Select the image index for firmware update

  return 0;

}


int XMOS_DFU_SaveState()
{ 
    return 0;
}

int XMOS_DFU_LoadState()
{
    return 0;
}

int DFUDeviceRequests(XUD_ep ep0_out, XUD_ep &?ep0_in, SetupPacket &sp, chanend ?c_user_cmd, unsigned int altInterface, unsigned int user_reset) {
  unsigned int return_data_len = 0;
  unsigned int data_buffer_len = 0;
  unsigned int data_buffer[17];
  unsigned int reset_device_after_ack = 0;
 
  if(sp.bmRequestType.Direction == BM_REQTYPE_DIRECTION_OUT) 
  { // Host to device
    if (sp.wLength) 
#ifdef ARCH_G
      data_buffer_len = XUD_GetBuffer_(ep0_out, 0, (data_buffer, unsigned char[]));
#else
      data_buffer_len = XUD_GetBuffer(ep0_out, (data_buffer, unsigned char[]));
#endif
  }

  // Map Standard DFU commands onto device level firmware upgrade mechanism
  switch (sp.bRequest) {
    case DFU_DETACH:
      return_data_len = DFU_Detach(sp.wValue, c_user_cmd);
      break;
    case DFU_DNLOAD:
      return_data_len = DFU_Dnload(sp.wLength, sp.wValue, data_buffer, c_user_cmd);
      break;
    case DFU_UPLOAD:
      return_data_len = DFU_Upload(sp.wLength, sp.wValue, data_buffer, c_user_cmd);
      break;
    case DFU_GETSTATUS:
      return_data_len = DFU_GetStatus(sp.wLength, data_buffer, c_user_cmd);
      break;
    case DFU_CLRSTATUS:
      return_data_len = DFU_ClrStatus();
      break;
    case DFU_GETSTATE:
      return_data_len = DFU_GetState(sp.wLength, data_buffer, c_user_cmd);
      break;
    case DFU_ABORT:
      return_data_len = DFU_Abort();
      break;
    /* XMOS Custom DFU requests */
    case XMOS_DFU_RESETDEVICE:
      reset_device_after_ack = 1;
      return_data_len = 0;
      break;
    case XMOS_DFU_REVERTFACTORY:
      return_data_len = XMOS_DFU_RevertFactory(c_user_cmd);
      break;
    case XMOS_DFU_RESETINTODFU:
      reset_device_after_ack = 1;
      DFU_reset_override = 0x11042011;
      return_data_len = 0;
      break;
    case XMOS_DFU_RESETFROMDFU:
      reset_device_after_ack = 1;
      DFU_reset_override = 0;
      return_data_len = 0;
      break;
    case XMOS_DFU_SELECTIMAGE:
      return_data_len = XMOS_DFU_SelectImage(sp.wValue, c_user_cmd);
      break;
    case XMOS_DFU_SAVESTATE:
      /* Save passed state to flash */
      return_data_len = XMOS_DFU_SaveState();
      break;
    case XMOS_DFU_RESTORESTATE:
      /* Restore saved state from flash */
      return_data_len = XMOS_DFU_LoadState();
      break;
    default:
      break;
  }

  if (sp.bmRequestType.Direction == BM_REQTYPE_DIRECTION_IN && sp.wLength != 0) { // Device to host
#ifdef ARCH_G
    XUD_DoGetRequest(ep0_out, 0, (data_buffer, unsigned char[]), return_data_len, return_data_len);
#else
    XUD_DoGetRequest(ep0_out, ep0_in, (data_buffer, unsigned char[]), return_data_len, return_data_len);
#endif
  } else {
#ifdef ARCH_G
    XUD_DoSetRequestStatus(ep0_out, 0);
#else
    XUD_DoSetRequestStatus(ep0_in, 0);
#endif
  }

  	// If device reset requested, handle after command acknowledgement
  	if (reset_device_after_ack) 
  	{
		if (!user_reset) 
		{
      		unsigned int cmd_data[16];
      			HandleUserDeviceRequest(FLASH_CMD_REBOOT, 1, 0, cmd_data, c_user_cmd);
    	} 
		else 
		{
      		return 1; 
    	}
  	}

  	return 0;
}