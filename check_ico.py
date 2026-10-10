from PIL import Image
img = Image.open(r'windows\runner\resources\app_icon.ico')
print(f'ICO format, size: {img.size}, mode: {img.mode}')

# Check multiple frames by seeking
for i in range(10):
    try:
        img.seek(i)
        print(f'Frame {i}: {img.size}')
    except EOFError:
        break
    except:
        pass

# Compare with source
src = Image.open(r'lib\assets\icons\icon-512.png')
print(f'\nSource icon-512.png: {src.size}, mode: {src.mode}')