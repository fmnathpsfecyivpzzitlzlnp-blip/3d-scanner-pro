from fastapi import FastAPI, UploadFile, File, BackgroundTasks
import shutil
import os
import cv2
import subprocess  # Библиотека для запуска сторонних программ

app = FastAPI()

SAVE_DIR = "uploaded_videos"
FRAMES_DIR = "extracted_frames"
MESHES_DIR = "output_meshes"  # Папка для готовых 3D-моделей

# !!! ВАЖНО: Укажи здесь точный путь к файлу meshroom_batch.exe !!!
MESHROOM_EXE = r"c:\Meshroom-2025.1.0\meshroom_batch.exe"

os.makedirs(SAVE_DIR, exist_ok=True)
os.makedirs(FRAMES_DIR, exist_ok=True)
os.makedirs(MESHES_DIR, exist_ok=True)


# --- 1. ФУНКЦИЯ НАРЕЗКИ (Из прошлого шага) ---
def extract_frames(video_path: str, video_name_without_ext: str):
    print(f"🎬 Начинаю нарезку кадров...")
    output_folder = os.path.join(FRAMES_DIR, video_name_without_ext)
    os.makedirs(output_folder, exist_ok=True)

    cam = cv2.VideoCapture(video_path)
    fps = cam.get(cv2.CAP_PROP_FPS)
    frame_skip = int(fps / 3)  # Берем 3 кадра в секунду

    current_frame = 0
    saved_count = 0

    while True:
        ret, frame = cam.read()
        if not ret: break
        if current_frame % frame_skip == 0:
            frame_name = os.path.join(output_folder, f"frame_{saved_count:04d}.jpg")
            cv2.imwrite(frame_name, frame)
            saved_count += 1
        current_frame += 1
    cam.release()
    print(f"✅ Нарезка завершена! Сохранено кадров: {saved_count}")
    return output_folder  # Возвращаем папку с фотками для следующего шага


# --- 2. ФУНКЦИЯ СОЗДАНИЯ 3D-МОДЕЛИ (Магия RTX 3090) ---
def build_3d_mesh(frames_folder: str, video_name_without_ext: str):
    print("🚀 Запускаю Meshroom. RTX 3090, твой выход!")

    # Создаем папку для результата
    output_mesh_folder = os.path.join(MESHES_DIR, video_name_without_ext)
    os.makedirs(output_mesh_folder, exist_ok=True)

    # Формируем команду для движка
    command = [
        MESHROOM_EXE,
        "--input", frames_folder,  # Откуда брать фото
        "--output", output_mesh_folder  # Куда положить 3D модель (файлы .obj и текстуры)
    ]

    try:
        # Запускаем процесс и ждем завершения
        subprocess.run(command, check=True)
        print(f"🎉 ПОБЕДА! 3D-модель успешно создана и лежит в: {output_mesh_folder}")
    except subprocess.CalledProcessError as e:
        print(f"❌ Ошибка при создании 3D-модели: {e}")
    except FileNotFoundError:
        print(f"❌ Ошибка: Не найден файл {MESHROOM_EXE}. Проверь путь!")


# --- ГЛАВНЫЙ КОНВЕЙЕР ОБРАБОТКИ ---
def process_video_pipeline(video_path: str, filename: str):
    video_name_without_ext = os.path.splitext(filename)[0]

    # Шаг 1: Нарезка
    frames_folder = extract_frames(video_path, video_name_without_ext)

    # Шаг 2: 3D Реконструкция
    build_3d_mesh(frames_folder, video_name_without_ext)


# --- РОУТЕР ПРИЕМА (Как и был) ---
@app.post("/upload")
async def receive_video(background_tasks: BackgroundTasks, video: UploadFile = File(...)):
    print(f"📥 Принимаю файл: {video.filename}")
    file_path = os.path.join(SAVE_DIR, video.filename)

    with open(file_path, "wb") as buffer:
        shutil.copyfileobj(video.file, buffer)

    print(f"💾 Файл сохранен: {file_path}")

    # Запускаем весь конвейер в фоне
    background_tasks.add_task(process_video_pipeline, file_path, video.filename)
    return {"status": "success", "message": "Видео на сервере. Начинаю генерацию 3D!"}