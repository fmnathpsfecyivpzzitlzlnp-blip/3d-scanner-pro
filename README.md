# 📱 3D Scanner Pro: Mobile-to-Server Photogrammetry Pipeline

A comprehensive solution for creating 3D models of real-world objects using your smartphone and a home PC. 

This project consists of a mobile application (built with Flutter) that acts as a smart viewfinder with motion-blur protection, and a powerful Python backend that automates video frame extraction and runs the photogrammetry pipeline (Meshroom) on your GPU.

## 🚀 How It Works

1. **Capture (Mobile):** The user smoothly moves the camera around an object. Built-in gyroscope and accelerometer sensors monitor the operator's speed. If the movement is too jerky (which causes motion blur), the screen flashes a red warning.
2. **Transfer:** Once recording is finished, the `.mp4` video file is sent over the local Wi-Fi network to the server.
3. **Processing (Server):** The server instantly receives the file, uses OpenCV to extract high-quality frames (3 frames per second), and feeds them into the AliceVision Meshroom engine.
4. **Render (GPU):** Your graphics card (NVIDIA RTX recommended) calculates the point cloud and generates a ready-to-use 3D model in `.obj` format with `.exr` textures.

---

## 🛠 Tech Stack

**Frontend (Mobile App):**
* [Flutter](https://flutter.dev/) (Dart)
* `camera` (Device lens access)
* `sensors_plus` (Gyroscope and Accelerometer data)
* `http` (Multipart POST requests)

**Backend (Server):**
* [Python 3.10+](https://www.python.org/)
* [FastAPI](https://fastapi.tiangolo.com/) + Uvicorn (Fast asynchronous web server)
* [OpenCV](https://opencv.org/) (`cv2` for frame extraction)
* [AliceVision Meshroom](https://alicevision.org/) (3D Reconstruction Engine)

---

## ⚙️ Installation & Setup (Backend Server)

### System Requirements:
* OS: Windows 10/11 or Linux
* GPU: **NVIDIA with CUDA support** (Highly recommended for fast generation. e.g., RTX 3090, 4080)
* Python installed.

### Steps:
1. Download and extract [Meshroom (Windows 64-bit)](https://alicevision.org/#meshroom) to a convenient folder (e.g., `C:\Meshroom`).
2. Navigate to the server directory:
   ```bash
   cd backend_server
Install the required Python libraries:

Bash
pip install fastapi uvicorn python-multipart opencv-python
Open the server.py file and ensure the MESHROOM_EXE variable points to the correct path of your meshroom_batch.exe.

Run the server (it will be accessible on your local Wi-Fi network):

Bash
uvicorn server:app --host 0.0.0.0 --port 8000
Note: Ensure your Windows Firewall, VPN, or ZeroTier is not blocking local connections on port 8000.

📱 Installation & Setup (Mobile Client)
Install the Flutter SDK.

Navigate to the mobile app folder:

Bash
cd mobile_app
Fetch all dependencies:

Bash
flutter pub get
Important: Open the lib/main.dart file and locate the uploadVideo() function. Replace the IP address 192.168.X.X with the actual IPv4 address of the computer running your Python server.

Dart
var uri = Uri.parse('[http://192.168.](http://192.168.)X.X:8000/upload');
Connect your Android/iOS device via USB (with Developer/Debug mode enabled) and run the project:

Bash
flutter run
💡 Tips for a Perfect 3D Scan
To ensure the photogrammetry algorithms work flawlessly, follow these rules during capture:

Lighting: Avoid harsh shadows from the sun or direct lamps. Diffused, even lighting is your best friend.

Materials: The engine cannot process completely black, transparent (glass), or highly reflective (chrome, mirrors) surfaces. Choose matte objects with rich textures.

Movement: Do not rotate the object! The object must remain stationary while the camera moves around it (at least 2-3 full circles at different heights).

Watch the HUD: The built-in AR crosshair and red frame will warn you if you are moving the phone too fast.