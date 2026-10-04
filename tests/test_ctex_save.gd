extends SceneTree
## 测试: 解码→半尺寸→重压缩→ResourceSaver 存回 .ctex 是否保持 DXT+mipmaps
func _init() -> void:
        var src := "res://assets/textures/02455971aa5d1a9c.ctex"  # DXT5 1024x1024 (法线)
        var t: Texture2D = load(src)
        var img: Image = t.get_image()
        print("ORIG fmt=", img.get_format(), " w=", img.get_width(), " mips=", img.has_mipmaps(), " bytes=", img.get_data().size())
        if img.is_compressed():
                var e1: int = img.decompress()
                print("decompress err=", e1, " fmt=", img.get_format())
        img.resize(img.get_width() / 2, img.get_height() / 2, Image.INTERPOLATE_LANCZOS)
        var e2: int = img.generate_mipmaps()
        print("resize+mips err=", e2, " w=", img.get_width(), " mips=", img.has_mipmaps())
        var e3: int = img.compress(Image.COMPRESS_S3TC, Image.COMPRESS_SOURCE_GENERIC, Image.ASTC_FORMAT_4x4)
        print("compress err=", e3, " fmt=", img.get_format(), " bytes=", img.get_data().size())
        var tex := ImageTexture.create_from_image(img)
        var err: int = ResourceSaver.save(tex, "/tmp/test_out.res")
        print("save err=", err)
        if err == OK:
                var t2: Texture2D = load("/tmp/test_out.res")
                if t2 == null:
                        print("RELOAD: null")
                else:
                        var i2: Image = t2.get_image()
                        print("RELOAD fmt=", i2.get_format(), " w=", i2.get_width(), " mips=", i2.has_mipmaps(), " bytes=", i2.get_data().size())
        quit(0)
