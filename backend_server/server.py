from fastapi import FastAPI, UploadFile, File, BackgroundTasks, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
import shutil
import os
import cv2
import asyncio

app = FastAPI()

SAVE_DIR = "uploaded_videos"
FRAMES_DIR = "extracted_frames"
MESHES_DIR = "output_meshes"
EXPORTS_DIR = "exports" # Папка для готовых FBX, GLB и т.д.

# !!! ТВОИ ПУТИ К ПРОГРАММАМ !!!
MESHROOM_EXE = r"C:\Meshroom\meshroom_batch.exe"
BLENDER_EXE = r"C:\Program Files\Blender Foundation\Blender 4.0\blender.exe"
BLENDER_SCRIPT = "convert.py"

for d in [SAVE_DIR, FRAMES_DIR, MESHES_DIR, EXPORTS_DIR]:
    os.makedirs(d, exist_ok=True)

# --- МЕНЕДЖЕР WEBSOCKET ---
class ConnectionManager:
    def __init__(self):
        self.active_connections: dict[str, WebSocket] = {}

    async def connect(self, websocket: WebSocket, client_id: str):
        await websocket.accept()
        self.active_connections[client_id] = websocket

    def disconnect(self, client_id: str):
        if client_id in self.active_connections:
            del self.active_connections[client_id]

    async def send_status(self, client_id: str, message: str):
        if client_id in self.active_connections:
            await self.active_connections[client_id].send_text(message)

manager = ConnectionManager()

@app.websocket("/ws/{client_id}")
async def websocket_endpoint(websocket: WebSocket, client_id: str):
    await manager.connect(websocket, client_id)
    try:
        while True:
            await websocket.receive_text() # Держим соединение открытым
    except WebSocketDisconnect:
        manager.disconnect(client_id)

# --- КОНВЕЙЕР ОБРАБОТКИ ---
async def process_video_pipeline(video_path: str, filename: str, client_id: str):
    video_name_without_ext = os.path.splitext(filename)[0]
    
    # ЭТАП 1: Нарезка кадров
    await manager.send_status(client_id, "✂️ Нарезка кадров (OpenCV)...")
    output_frames_folder = os.path.join(FRAMES_DIR, video_name_without_ext)
    os.makedirs(output_frames_folder, exist_ok=True)
    
    cam = cv2.VideoCapture(video_path)
    fps = cam.get(cv2.CAP_PROP_FPS)
    frame_skip = int(fps / 3) if fps else 10
    current_frame = saved_count = 0
    
    while True:
        ret, frame = cam.read()
        if not ret: break
        if current_frame % frame_skip == 0:
            cv2.imwrite(os.path.join(output_frames_folder, f"frame_{saved_count:04d}.jpg"), frame)
            saved_count += 1
        current_frame += 1
    cam.release()
    
    # ЭТАП 2: Meshroom (RTX 3090)
    await manager.send_status(client_id, f"🚀 Запуск Meshroom (Кадров: {saved_count}). Ждем магию RTX...")
    output_mesh_folder = os.path.join(MESHES_DIR, video_name_without_ext)
    os.makedirs(output_mesh_folder, exist_ok=True)
    
    meshroom_cmd = [MESHROOM_EXE, "--input", output_frames_folder, "--output", output_mesh_folder]
    process = await asyncio.create_subprocess_exec(*meshroom_cmd)
    await process.communicate()
    
    # ЭТАП 3: Авто-генерация GLB для предпросмотра на телефоне
    await manager.send_status(client_id, "📦 Оптимизация для мобилки (Создание GLB)...")
    obj_path = os.path.join(output_mesh_folder, "texturedMesh.obj")
    preview_glb_path = os.path.join(EXPORTS_DIR, f"{video_name_without_ext}.glb")
    
    if os.path.exists(obj_path):
        blender_cmd = [
            BLENDER_EXE, "--background", "--python", BLENDER_SCRIPT, "--", 
            obj_path, preview_glb_path, "glb"
        ]
        b_process = await asyncio.create_subprocess_exec(*blender_cmd)
        await b_process.communicate()
        
        await manager.send_status(client_id, "✅ ГОТОВО! Модель доступна для просмотра.")
    else:
        await manager.send_status(client_id, "❌ Ошибка Meshroom: OBJ файл не создан.")

# --- РОУТЕР ЗАГРУЗКИ ВИДЕО ---
@app.post("/upload/{client_id}")
async def receive_video(client_id: str, background_tasks: BackgroundTasks, video: UploadFile = File(...)):
    file_path = os.path.join(SAVE_DIR, video.filename)
    with open(file_path, "wb") as buffer:
        shutil.copyfileobj(video.file, buffer)
        
    background_tasks.add_task(process_video_pipeline, file_path, video.filename, client_id)
    return {"status": "success"}

# --- НОВЫЙ РОУТЕР: ЭКСПОРТ В ЛЮБОЙ ФОРМАТ ---
@app.get("/export/{filename}/{format}")
async def export_model(filename: str, format: str):
    """Генерирует нужный формат по запросу (on-demand) и отдает файл"""
    video_name_without_ext = os.path.splitext(filename)[0]
    obj_path = os.path.join(MESHES_DIR, video_name_without_ext, "texturedMesh.obj")
    output_file = os.path.join(EXPORTS_DIR, f"{video_name_without_ext}.{format}")
    
    if not os.path.exists(obj_path):
        return {"error": "Базовая модель OBJ не найдена"}
        
    # Если файл уже конвертировали ранее - отдаем сразу
    if not os.path.exists(output_file):
        print(f"🔄 Запрос формата {format.upper()}. Запускаю Blender...")
        blender_cmd = [
            BLENDER_EXE, "--background", "--python", BLENDER_SCRIPT, "--", 
            obj_path, output_file, format
        ]
        process = await asyncio.create_subprocess_exec(*blender_cmd)
        await process.communicate()

    return FileResponse(path=output_file, filename=f"{video_name_without_ext}.{format}")

@app.get("/")
def read_root(): return {"message": "Server Online"}