#=
The title of the window of a live view, see `_set_title!` of the package: e.g. the name of the folder
of its project after "Save as"
=#

function GUI._set_screen_title!(screen::GLMakie.Screen, title::String)
    window = screen.glscreen
    # A window of GLFW that is open; an embedded screen has another window type
    (window isa GLMakie.GLFW.Window && isopen(screen)) || return nothing
    GLMakie.GLFW.SetWindowTitle(window, title)
    return nothing
end
