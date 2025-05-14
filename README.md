# StraatScan: Object Detection iOS App

## Overview

This iOS application is designed to perform real-time object detection using the device's camera. It processes the captured video frames, identifies relevant objects using a CoreML model (YOLOv11), blurs potentially sensitive areas (like people or license plates if detected), draws bounding boxes around containers, and uploads the processed image along with metadata (including GPS coordinates) to Azure IoT Hub for further analysis or monitoring.

## Requirements

* Xcode 15 or later
* iOS 17.0 or later
* Azure CLI
* An Azure IoT Hub instance with a registered device.

## Setup Instructions

Follow these steps to set up the project for development:

### **Clone the Repository:**
```bash
git clone git@github.com:Computer-Vision-Team-Amsterdam/StraatScan.git
cd StraatScan
```

### **Secrets Configuration (`Secrets.xcconfig`)**

This project uses `.xcconfig` files to manage build-time secrets like the Azure IoT Hub Device ID and SAS Token, keeping them out of source control. You need to create a `Secrets.xcconfig` file.

a.  **Create the File:** In the root directory of the project (where your `.xcodeproj` file is), create a new file named `Secrets.xcconfig`.

b.  **Device Connection String:** Navigate to your IoT Hub in the Azure Portal, go to "Devices", select your target device, and find its "Primary Connection String" (or Secondary). You'll need this to generate the SAS token. **Do not put the connection string itself in the secrets file.**

c.  **Get Azure Credentials:**
* **Device ID (`DEVICE_ID`):** Find the ID of the registered device within your Azure IoT Hub instance in the Azure Portal.
* **Device Connection String:** Navigate to your IoT Hub in the Azure Portal, go to "Devices", select your target device, and find its "Primary Connection String" (or Secondary). You'll need this to generate the SAS token. **Do not put the connection string itself in the secrets file.**
* **Generate SAS Token (`DEVICE_SAS_TOKEN`):**
    1.  Open your terminal or command prompt.
    2.  Make sure you have Azure CLI installed and are logged in (`az login`).
    3.  Run the following command, replacing `<Your_Device_Connection_String>` with the actual connection string copied from the Azure Portal:
        ```bash
        az iot hub generate-sas-token --connection-string '<Your_Device_Connection_String>'
        ```
    4.  This command will output a JSON object containing the SAS token (usually under the `sas` key). Copy the **full SAS token value** (it's typically quite long).
    5.  *Note:* By default, this token might expire. For development, you can increase the duration using `--duration <seconds>`, e.g., `--duration 31536000` for a year. Be mindful of security implications for long-lived tokens.

d. **Populate `Secrets.xcconfig`:** Add the `DEVICE_ID` and `DEVICE_SAS_TOKEN` keys with the values obtained above:
```xcconfig
// Secrets.xcconfig

DEVICE_ID = Your_Device_ID_Here
DEVICE_SAS_TOKEN = Your_Generated_SAS_Token_Here
```

*(Project Configuration Note: The project should already be configured to use `Debug.xcconfig` and `Release.xcconfig`, which in turn `#include "Secrets.xcconfig"` to load these values at build time and inject them into the `Info.plist`.)*

### **Build & Run:**
* Open the `.xcodeproj` file in Xcode.
* Select your target device or simulator.
* Build and run the application (`Cmd + R`).

On the first launch after installing, the application should read the `DEVICE_ID` and `DEVICE_SAS_TOKEN` from the build configuration (via `Info.plist`), save them securely to the Keychain, and then use them for communication with Azure IoT Hub.
