#include <M5Stack.h>
#include <Usb.h>
#include <usbhub.h>
#include <hiduniversal.h>

// USB Host Global Objects
USB Usb;
USBHub Hub(&Usb);
HIDUniversal Hid(&Usb);
String lastTxData = "";

// Data structure to hold controller state
struct ControllerState {
    uint8_t raw[64]; // Raw report data buffer
    uint8_t rawLen;
    
    // Interpreted values (Standard Switch HID mapping assumption)
    // Adjust these based on actual raw data observation if needed
    bool btnA, btnB, btnX, btnY;
    bool btnL, btnR, btnZL, btnZR;
    bool btnMinus, btnPlus, btnHome, btnCapture;
    bool btnLStick, btnRStick;
    uint8_t dpad; // Hat switch value (0-7, 8=center)
    uint8_t lX, lY;
    uint8_t rX, rY;
} padState;

// HID Report Parser Implementation
class ControllerParser : public HIDReportParser {
public:
    void Parse(USBHID *hid, bool is_rpt_id, uint8_t len, uint8_t *buf) {
        // Copy raw data for debugging
        if (len > 64) len = 64;
        memcpy(padState.raw, buf, len);
        padState.rawLen = len;

        // --- Parsing Logic (Tentative for HORI/Switch Wired) ---
        // Typical Switch Wired format (varies by manufacturer, but often similar)
        // Byte 0: Button bits (bit0=Y, bit1=B, bit2=A, bit3=X, bit4=L, bit5=R, bit6=ZL, bit7=ZR)
        // Byte 1: Button bits (bit0=-, bit1=+, bit2=LClick, bit3=RClick, bit4=Home, bit5=Capture)
        // Byte 2: DPAD (Hat Switch) low nibble? Or Byte 2 is HAT + bits.

        padState.btnY = (buf[0] & 0x01);
        padState.btnB = (buf[0] & 0x02);
        padState.btnA = (buf[0] & 0x04);
        padState.btnX = (buf[0] & 0x08);
        padState.btnL = (buf[0] & 0x10);
        padState.btnR = (buf[0] & 0x20);
        padState.btnZL = (buf[0] & 0x40);
        padState.btnZR = (buf[0] & 0x80);

        padState.btnMinus   = (buf[1] & 0x01);
        padState.btnPlus    = (buf[1] & 0x02);
        padState.btnLStick  = (buf[1] & 0x04);
        padState.btnRStick  = (buf[1] & 0x08);
        padState.btnHome    = (buf[1] & 0x10);
        padState.btnCapture = (buf[1] & 0x20);

        padState.dpad = buf[2] & 0x0F; // Low nibble usually Hat Switch

        padState.lX = buf[3];
        padState.lY = buf[4];
        padState.rX = buf[5];
        padState.rY = buf[6];
    }
} parser;

// Wireless Communication Globals
unsigned long lastSendTime = 0;
const unsigned long SEND_INTERVAL_MS = 200;

// --- Setup & Loop ---
void setup() {
    // Disable USB Serial (3rd arg = false) to suppress debug output
    // M5.begin(LCDEnable, SDEnable, SerialEnable, I2CEnable);
    // I2C must be enabled for Power Management (IP5306)
    M5.begin(true, true, false, true);

    M5.Power.begin();
    M5.Lcd.setTextSize(2);
    M5.Lcd.println("M5 Controller Monitor");
    M5.Lcd.setTextSize(1);
    M5.Lcd.println("Init USB Host...");

    if (Usb.Init() == -1) {
        M5.Lcd.setTextColor(RED);
        M5.Lcd.println("OSC did not start.");
        while (1); // Halt
    }
    M5.Lcd.setTextColor(GREEN);
    M5.Lcd.println("USB Host Init OK");
    M5.Lcd.setTextColor(WHITE);

    if (!Hid.SetReportParser(0, &parser)) {
        M5.Lcd.println("SetReportParser Error");
    }
    
    // Initialize Serial2 for Wireless Module
    // Rx: 16, Tx: 17, 115200bps
    Serial2.begin(115200, SERIAL_8N1, 16, 17);
    M5.Lcd.println("Serial2 Started (115200)");

    M5.Lcd.println("Waiting for 5 seconds...");
    delay(5000);
}

void drawControllerInfo() {
    // Clear everything below title
    M5.Lcd.setCursor(0, 15);
    M5.Lcd.fillRect(0, 15, 320, 220, BLACK); 

    // Raw Hex Dump (First 8 bytes)
    M5.Lcd.setCursor(0, 30);
    M5.Lcd.setTextColor(YELLOW);
    M5.Lcd.print("RAW: ");
    for(int i=0; i<8 && i<padState.rawLen; i++) {
        M5.Lcd.printf("%02X ", padState.raw[i]);
    }
    M5.Lcd.println();
    M5.Lcd.setTextColor(WHITE);
    
    // Buttons
    M5.Lcd.setCursor(0, 50);
    M5.Lcd.printf("A:%d B:%d X:%d Y:%d\n", padState.btnA, padState.btnB, padState.btnX, padState.btnY);
    M5.Lcd.printf("L:%d R:%d ZL:%d ZR:%d\n", padState.btnL, padState.btnR, padState.btnZL, padState.btnZR);
    M5.Lcd.printf("-:%d +:%d H:%d C:%d\n", padState.btnMinus, padState.btnPlus, padState.btnHome, padState.btnCapture);
    
    // DPAD Decoding
    String dpadStr = "CENTER";
    int dx = 0, dy = 0;
    switch(padState.dpad) {
        case 0: dpadStr = "UP";    dy = -1; break;
        case 1: dpadStr = "UP-R";  dx = 1; dy = -1; break;
        case 2: dpadStr = "RIGHT"; dx = 1; break;
        case 3: dpadStr = "DW-R";  dx = 1; dy = 1; break;
        case 4: dpadStr = "DOWN";  dy = 1; break;
        case 5: dpadStr = "DW-L";  dx = -1; dy = 1; break;
        case 6: dpadStr = "LEFT";  dx = -1; break;
        case 7: dpadStr = "UP-L";  dx = -1; dy = -1; break;
        default: break;
    }
    M5.Lcd.printf("LS:%d RS:%d DP:%s\n", padState.btnLStick, padState.btnRStick, dpadStr.c_str());
    
    // Sticks
    M5.Lcd.setCursor(0, 100);
    M5.Lcd.printf("L Stick: X=%3d Y=%3d\n", padState.lX, padState.lY);
    M5.Lcd.printf("R Stick: X=%3d Y=%3d\n", padState.rX, padState.rY);

    // Visual Stick Representation (Simple Box)
    // Left Stick
    int cx = 60, cy = 160, r = 25;
    M5.Lcd.drawRect(cx-r, cy-r, r*2, r*2, DARKGREY);
    int lx = map(padState.lX, 0, 255, -r, r);
    int ly = map(padState.lY, 0, 255, -r, r);
    M5.Lcd.fillCircle(cx+lx, cy+ly, 4, GREEN);
    M5.Lcd.setCursor(cx-10, cy+r+5); M5.Lcd.print("LS");

    // Right Stick
    cx = 160; 
    M5.Lcd.drawRect(cx-r, cy-r, r*2, r*2, DARKGREY);
    int rx = map(padState.rX, 0, 255, -r, r);
    int ry = map(padState.rY, 0, 255, -r, r);
    M5.Lcd.fillCircle(cx+rx, cy+ry, 4, GREEN);
    M5.Lcd.setCursor(cx-10, cy+r+5); M5.Lcd.print("RS");

    // DPAD Visual
    cx = 260;
    M5.Lcd.drawRect(cx-r, cy-r, r*2, r*2, DARKGREY);
    // Draw cross guide
    M5.Lcd.drawLine(cx-r, cy, cx+r, cy, DARKGREY);
    M5.Lcd.drawLine(cx, cy-r, cx, cy+r, DARKGREY);
    
    if (padState.dpad != 8) {
        M5.Lcd.fillCircle(cx + (dx * 15), cy + (dy * 15), 6, YELLOW);
    } else {
        M5.Lcd.fillCircle(cx, cy, 4, DARKGREY);
    }
    M5.Lcd.setCursor(cx-15, cy+r+5); M5.Lcd.print("DPAD");

    // Display sent data
    M5.Lcd.setCursor(0, 215);
    M5.Lcd.setTextColor(CYAN);
    M5.Lcd.print("TX: " + lastTxData);
    M5.Lcd.setTextColor(WHITE);
}

unsigned long lastDraw = 0;

void loop() {
    Usb.Task();
    M5.update();
    
    // Update screen at 30FPS to avoid flicker
    if (millis() - lastDraw > 33) {
        drawControllerInfo();
        lastDraw = millis();
    }

    // Wireless Data Transmission (every 200ms)
    if (millis() - lastSendTime >= SEND_INTERVAL_MS) {
        lastSendTime = millis();
        
        // 1. Clear receive buffer (ignore incoming data like "OK")
        while (Serial2.available()) {
            Serial2.read();
        }

        // 2. Prepare Data Packet
        // Byte 0: A, B, X, Y, L, R, ZL, ZR
        uint8_t byte0 = 0;
        if (padState.btnA)  byte0 |= 0x01;
        if (padState.btnB)  byte0 |= 0x02;
        if (padState.btnX)  byte0 |= 0x04;
        if (padState.btnY)  byte0 |= 0x08;
        if (padState.btnL)  byte0 |= 0x10;
        if (padState.btnR)  byte0 |= 0x20;
        if (padState.btnZL) byte0 |= 0x40;
        if (padState.btnZR) byte0 |= 0x80;

        // Byte 1: -, +, Home, Cap, LClk, RClk
        uint8_t byte1 = 0;
        if (padState.btnMinus)   byte1 |= 0x01;
        if (padState.btnPlus)    byte1 |= 0x02;
        if (padState.btnHome)    byte1 |= 0x04;
        if (padState.btnCapture) byte1 |= 0x08;
        if (padState.btnLStick)  byte1 |= 0x10; // Click
        if (padState.btnRStick)  byte1 |= 0x20; // Click

        // Byte 2: DPAD (0=Neutral, 1=UP, ... 8=UP-LEFT)
        // Original: 0=UP, 1=UP-R ... 7=UP-L, 0x0F=Neutral
        uint8_t byte2 = 0;
        if (padState.dpad == 0x0F || padState.dpad == 8) {
             byte2 = 0; // Neutral
        } else {
             byte2 = (padState.dpad & 0x0F) + 1;
        }

        // Byte 3-6: Sticks
        uint8_t byte3 = padState.lX;
        uint8_t byte4 = padState.lY;
        uint8_t byte5 = padState.rX;
        uint8_t byte6 = padState.rY;

        // 3. Send Formatted String
        // Format: "XX,XX,XX,XX,XX,XX,XX\r\n"
        char buf[64];
        snprintf(buf, sizeof(buf), "%02X,%02X,%02X,%02X,%02X,%02X,%02X\r\n",
            byte0, byte1, byte2, byte3, byte4, byte5, byte6);
        Serial2.print(buf);
        
        // Update LCD display variable
        lastTxData = String(buf);
        lastTxData.trim(); // Remove newline for clean display
    }
}
