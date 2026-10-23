#=
Groups made in the window: a selection of several objects becomes an `ObjectGroup` (`Ctrl+G`),
which is ungrouped again (`Ctrl+Shift+G`), see `_group!` and `_ungroup!`
=#

"""
    _WindowGroup(members, pivot, poses)

The record of an `ObjectGroup` that was made in the window from a selection of several objects,
see `_group!`: its `members` in their order, the `pivot` [m] that it got (`set_pivot3d!`, the mean
of the positions of the members) and the `poses` `(P, R)` of the members when it was made, from
which `export_script` writes the members and then the group, see `gui.components.groups`.
"""
struct _WindowGroup
    members::Vector{Any}
    pivot::Vector{Float64}
    poses::IdDict{Any, Tuple{Point3{Float64}, Matrix{Float64}}}
end

"""Returns whether `g` is a group made in the window of the `gui`, see `_group!`."""
_is_window_group(gui, @nospecialize(g)) = haskey(gui.components.groups, g)

"""
    _group_reason(gui, sel) -> Union{Nothing, String}

Why the selection `sel` of the controls of the `gui` can not be made a group (see `_group!`), for
the status line, or `nothing` if it can: a selection of several movable top-level components with
the same systems (or none), no source, clip plane or static object.
"""
function _group_reason(gui, @nospecialize(sel))
    return "grouping is not implemented yet"
end

"""
    _group!(gui, sel) -> Union{Nothing, BMO.ObjectGroup}

Makes the selection of several objects `sel` of the `gui` an `ObjectGroup`, like `Ctrl+G`: the
systems of its objects hold the group instead of them, the group is selected and moved, rotated,
hidden and browsed like a group of the script. One action of the undo history. Returns the group,
or `nothing` with the reason in the status line, see `_group_reason`.
"""
function _group!(gui, @nospecialize(sel))
    gui.status.text[] = something(_group_reason(gui, sel), "")
    return nothing
end

"""
    _ungroup!(gui, g) -> Bool

Ungroups the group `g` that was made in the window of the `gui` (see `_group!`), like
`Ctrl+Shift+G`: its systems hold its members again, at their current poses, which are selected as a
selection of several. One action of the undo history. Returns `false` with a status line if `g` is
not a group made in the window.
"""
function _ungroup!(gui, @nospecialize(g))
    gui.status.text[] = "ungrouping is not implemented yet"
    return false
end
