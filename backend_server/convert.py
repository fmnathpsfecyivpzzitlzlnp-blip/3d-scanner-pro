import bpy
import sys
import os

# Получаем аргументы от нашего сервера
argv = sys.argv
argv = argv[argv.index("--") + 1:] 
input_obj = argv[0]
output_file = argv[1]
export_format = argv[2].lower()

# Очищаем сцену Блендера
bpy.ops.wm.read_factory_settings(use_empty=True)

# Импортируем сырой OBJ из Meshroom
bpy.ops.wm.obj_import(filepath=input_obj)

# Конвертируем и экспортируем
if export_format in ["glb", "gltf"]:
    bpy.ops.export_scene.gltf(filepath=output_file, export_format='GLB')
elif export_format == "fbx":
    bpy.ops.export_scene.fbx(filepath=output_file, use_selection=False)
elif export_format == "stl":
    bpy.ops.export_mesh.stl(filepath=output_file)
elif export_format == "dae":
    bpy.ops.wm.collada_export(filepath=output_file)

print(f"Конвертация в {export_format.upper()} завершена успешно!")