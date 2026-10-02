# Icons and flat icon buttons of the app layout of the live view
#
# Icon paths not marked "own design" are from Material Symbols (outlined, weight 400, grade 0,
# optical size 24) by Google, licensed under the Apache License 2.0:
#   https://github.com/google/material-design-icons (symbols/web/<name>/materialsymbolsoutlined)
#   https://www.apache.org/licenses/LICENSE-2.0
# The path data is used unchanged. The icons marked "own design" are drawn on the same grid.

using Makie: Observable, Point2f, Point2d, RGBAf, BezierPath, MoveTo, LineTo, CurveTo, ClosePath,
             Consume, lift, onany, on, translate!

# SVG path data on the Material Symbols grid: viewBox "0 -960 960 960", y down
const _ICON_SVG = Dict{Symbol, String}(
    # keep (outlined and filled): pin a card
    :pin => "m640-480 80 80v80H520v240l-40 40-40-40v-240H240v-80l80-80v-280h-40v-80h400v80h-40v280Zm-286 80h252l-46-46v-314H400v314l-46 46Zm126 0Z",
    :pinned => "m640-480 80 80v80H520v240l-40 40-40-40v-240H240v-80l80-80v-280h-40v-80h400v80h-40v280Z",
    # refresh
    :trace => "M480-160q-134 0-227-93t-93-227q0-134 93-227t227-93q69 0 132 28.5T720-690v-110h80v280H520v-80h168q-32-56-87.5-88T480-720q-100 0-170 70t-70 170q0 100 70 170t170 70q77 0 139-44t87-116h84q-28 106-114 173t-196 67Z",
    # autoplay
    :auto_trace => "M380-300v-360l280 180-280 180ZM480-40q-108 0-202.5-49.5T120-228v108H40v-240h240v80h-98q51 75 129.5 117.5T480-120q115 0 208.5-66T820-361l78 18q-45 136-160 219.5T480-40ZM42-520q7-67 32-128.5T143-762l57 57q-32 41-52 87.5T123-520H42Zm214-241-57-57q53-44 114-69.5T440-918v80q-51 5-97 25t-87 52Zm449 0q-41-32-87.5-52T520-838v-80q67 6 128.5 31T762-818l-57 57Zm133 241q-5-51-25-97.5T761-705l57-57q44 52 69 113.5T918-520h-80Z",
    # home
    :home => "M240-200h120v-240h240v240h120v-360L480-740 240-560v360Zm-80 80v-480l320-240 320 240v480H520v-240h-80v240H160Zm320-350Z",
    # fit_screen
    :fit => "M800-600v-120H680v-80h120q33 0 56.5 23.5T880-720v120h-80Zm-720 0v-120q0-33 23.5-56.5T160-800h120v80H160v120H80Zm600 440v-80h120v-120h80v120q0 33-23.5 56.5T800-160H680Zm-520 0q-33 0-56.5-23.5T80-240v-120h80v120h120v80H160Zm80-160v-320h480v320H240Zm80-80h320v-160H320v160Zm0 0v-160 160Z",
    # photo_camera
    :views => "M480-260q75 0 127.5-52.5T660-440q0-75-52.5-127.5T480-620q-75 0-127.5 52.5T300-440q0 75 52.5 127.5T480-260Zm0-80q-42 0-71-29t-29-71q0-42 29-71t71-29q42 0 71 29t29 71q0 42-29 71t-71 29ZM160-120q-33 0-56.5-23.5T80-200v-480q0-33 23.5-56.5T160-760h126l74-80h240l74 80h126q33 0 56.5 23.5T880-680v480q0 33-23.5 56.5T800-120H160Zm0-80h640v-480H638l-73-80H395l-73 80H160v480Zm320-240Z",
    # add_a_photo
    :save_view => "M440-440ZM120-120q-33 0-56.5-23.5T40-200v-480q0-33 23.5-56.5T120-760h126l74-80h240v80H355l-73 80H120v480h640v-360h80v360q0 33-23.5 56.5T760-120H120Zm640-560v-80h-80v-80h80v-80h80v80h80v80h-80v80h-80ZM440-260q75 0 127.5-52.5T620-440q0-75-52.5-127.5T440-620q-75 0-127.5 52.5T260-440q0 75 52.5 127.5T440-260Zm0-80q-42 0-71-29t-29-71q0-42 29-71t71-29q42 0 71 29t29 71q0 42-29 71t-71 29Z",
    # view_in_ar
    :orthographic => "M440-181 240-296q-19-11-29.5-29T200-365v-230q0-22 10.5-40t29.5-29l200-115q19-11 40-11t40 11l200 115q19 11 29.5 29t10.5 40v230q0 22-10.5 40T720-296L520-181q-19 11-40 11t-40-11Zm0-92v-184l-160-93v185l160 92Zm80 0 160-92v-185l-160 93v184ZM80-680v-120q0-33 23.5-56.5T160-880h120v80H160v120H80ZM280-80H160q-33 0-56.5-23.5T80-160v-120h80v120h120v80Zm400 0v-80h120v-120h80v120q0 33-23.5 56.5T800-80H680Zm120-600v-120H680v-80h120q33 0 56.5 23.5T880-800v120h-80ZM480-526l158-93-158-91-158 91 158 93Zm0 45Zm0-45Zm40 69Zm-80 0Z",
    # content_cut
    :clip => "M760-120 480-400l-94 94q8 15 11 32t3 34q0 66-47 113T240-80q-66 0-113-47T80-240q0-66 47-113t113-47q17 0 34 3t32 11l94-94-94-94q-15 8-32 11t-34 3q-66 0-113-47T80-720q0-66 47-113t113-47q66 0 113 47t47 113q0 17-3 34t-11 32l494 494v40H760ZM600-520l-80-80 240-240h120v40L600-520ZM240-640q33 0 56.5-23.5T320-720q0-33-23.5-56.5T240-800q-33 0-56.5 23.5T160-720q0 33 23.5 56.5T240-640Zm240 180q8 0 14-6t6-14q0-8-6-14t-14-6q-8 0-14 6t-6 14q0 8 6 14t14 6ZM240-160q33 0 56.5-23.5T320-240q0-33-23.5-56.5T240-320q-33 0-56.5 23.5T160-240q0 33 23.5 56.5T240-160Z",
    # flare
    :sources => "M40-440v-80h240v80H40Zm270-154-84-84 56-56 84 84-56 56Zm130-86v-240h80v240h-80Zm210 86-56-56 84-84 56 56-84 84Zm30 154v-80h240v80H680Zm-200 80q-50 0-85-35t-35-85q0-50 35-85t85-35q50 0 85 35t35 85q0 50-35 85t-85 35Zm198 134-84-84 56-56 84 84-56 56Zm-396 0-56-56 84-84 56 56-84 84ZM440-40v-240h80v240h-80Z",
    # straighten
    :measure => "M160-240q-33 0-56.5-23.5T80-320v-320q0-33 23.5-56.5T160-720h640q33 0 56.5 23.5T880-640v320q0 33-23.5 56.5T800-240H160Zm0-80h640v-320H680v160h-80v-160h-80v160h-80v-160h-80v160h-80v-160H160v320Zm120-160h80-80Zm160 0h80-80Zm160 0h80-80Zm-120 0Z",
    # ios_share
    :export => "M240-40q-33 0-56.5-23.5T160-120v-440q0-33 23.5-56.5T240-640h120v80H240v440h480v-440H600v-80h120q33 0 56.5 23.5T800-560v440q0 33-23.5 56.5T720-40H240Zm200-280v-447l-64 64-56-57 160-160 160 160-56 57-64-64v447h-80Z",
    # dock_to_right
    :panel_left => "M200-120q-33 0-56.5-23.5T120-200v-560q0-33 23.5-56.5T200-840h560q33 0 56.5 23.5T840-760v560q0 33-23.5 56.5T760-120H200Zm120-80v-560H200v560h120Zm80 0h360v-560H400v560Zm-80 0H200h120Z",
    # dock_to_left
    :panel_right => "M200-120q-33 0-56.5-23.5T120-200v-560q0-33 23.5-56.5T200-840h560q33 0 56.5 23.5T840-760v560q0 33-23.5 56.5T760-120H200Zm440-80h120v-560H640v560Zm-80 0v-560H200v560h360Zm80 0h120-120Z",
    # dock_to_bottom
    :panel_bottom => "M200-120q-33 0-56.5-23.5T120-200v-560q0-33 23.5-56.5T200-840h560q33 0 56.5 23.5T840-760v560q0 33-23.5 56.5T760-120H200Zm0-200v120h560v-120H200Zm0-80h560v-360H200v360Zm0 80v120-120Z",
    # help
    :help => "M478-240q21 0 35.5-14.5T528-290q0-21-14.5-35.5T478-340q-21 0-35.5 14.5T428-290q0 21 14.5 35.5T478-240Zm-36-154h74q0-33 7.5-52t42.5-52q26-26 41-49.5t15-56.5q0-56-41-86t-97-30q-57 0-92.5 30T342-618l66 26q5-18 22.5-39t53.5-21q32 0 48 17.5t16 38.5q0 20-12 37.5T506-526q-44 39-54 59t-10 73Zm38 314q-83 0-156-31.5T197-197q-54-54-85.5-127T80-480q0-83 31.5-156T197-763q54-54 127-85.5T480-880q83 0 156 31.5T763-763q54 54 85.5 127T880-480q0 83-31.5 156T763-197q-54 54-127 85.5T480-80Zm0-80q134 0 227-93t93-227q0-134-93-227t-227-93q-134 0-227 93t-93 227q0 134 93 227t227 93Zm0-320Z",
    # visibility
    :eye => "M480-320q75 0 127.5-52.5T660-500q0-75-52.5-127.5T480-680q-75 0-127.5 52.5T300-500q0 75 52.5 127.5T480-320Zm0-72q-45 0-76.5-31.5T372-500q0-45 31.5-76.5T480-608q45 0 76.5 31.5T588-500q0 45-31.5 76.5T480-392Zm0 192q-146 0-266-81.5T40-500q54-137 174-218.5T480-800q146 0 266 81.5T920-500q-54 137-174 218.5T480-200Zm0-300Zm0 220q113 0 207.5-59.5T832-500q-50-101-144.5-160.5T480-720q-113 0-207.5 59.5T128-500q50 101 144.5 160.5T480-280Z",
    # visibility_off
    :eye_off => "m644-428-58-58q9-47-27-88t-93-32l-58-58q17-8 34.5-12t37.5-4q75 0 127.5 52.5T660-500q0 20-4 37.5T644-428Zm128 126-58-56q38-29 67.5-63.5T832-500q-50-101-143.5-160.5T480-720q-29 0-57 4t-55 12l-62-62q41-17 84-25.5t90-8.5q151 0 269 83.5T920-500q-23 59-60.5 109.5T772-302Zm20 246L624-222q-35 11-70.5 16.5T480-200q-151 0-269-83.5T40-500q21-53 53-98.5t73-81.5L56-792l56-56 736 736-56 56ZM222-624q-29 26-53 57t-41 67q50 101 143.5 160.5T480-280q20 0 39-2.5t39-5.5l-36-38q-11 3-21 4.5t-21 1.5q-75 0-127.5-52.5T300-500q0-11 1.5-21t4.5-21l-84-82Zm319 93Zm-151 75Z",
    # chevron_right
    :expand => "M504-480 320-664l56-56 240 240-240 240-56-56 184-184Z",
    # expand_more
    :collapse => "M480-345 240-585l56-56 184 184 184-184 56 56-240 240Z",
    # folder
    :group => "M160-160q-33 0-56.5-23.5T80-240v-480q0-33 23.5-56.5T160-800h240l80 80h320q33 0 56.5 23.5T880-640v400q0 33-23.5 56.5T800-160H160Zm0-80h640v-400H447l-80-80H160v480Zm0 0v-480 480Z",
    # deployed_code
    :mesh => "M440-183v-274L200-596v274l240 139Zm80 0 240-139v-274L520-457v274Zm-40-343 237-137-237-137-237 137 237 137ZM160-252q-19-11-29.5-29T120-321v-318q0-22 10.5-40t29.5-29l280-161q19-11 40-11t40 11l280 161q19 11 29.5 29t10.5 40v318q0 22-10.5 40T800-252L520-91q-19 11-40 11t-40-11L160-252Zm320-228Z",
    # category
    :object => "m260-520 220-360 220 360H260ZM700-80q-75 0-127.5-52.5T520-260q0-75 52.5-127.5T700-440q75 0 127.5 52.5T880-260q0 75-52.5 127.5T700-80Zm-580-20v-320h320v320H120Zm580-60q42 0 71-29t29-71q0-42-29-71t-71-29q-42 0-71 29t-29 71q0 42 29 71t71 29Zm-500-20h160v-160H200v160Zm202-420h156l-78-126-78 126Zm78 0ZM360-340Zm340 80Z",
    # Own designs, in the outlined style of Material Symbols: strokes of 80 units (2 px at 24 px),
    # solid parts clockwise, holes counterclockwise (nonzero fill rule of FreeType)
    # own design: a warning triangle with an exclamation mark, the message of a failed solve
    :warning => "M480-880L920-120L40-120ZM480-720L178-200L782-200ZM440-560L520-560L520-360L440-360ZM440-320L520-320L520-240L440-240Z",
    # own design: a ray that ends at a plane in perspective, dashed behind it
    :clip_beams => "M500-720L640-880L640-240L500-80ZM80-520L500-520L500-440L80-440ZM700-520L780-520L780-440L700-440ZM820-520L880-520L880-440L820-440Z",
    # own design: biconvex lens with flat edges, the optical axis on both sides
    :lens => "M400-880H560Q840-480 560-80H400Q120-480 400-880ZM440-800Q160-480 440-160H520Q720-480 520-800ZM80-520L200-520L200-440L80-440ZM760-520L880-520L880-440L760-440Z",
    # own design: thick mirror with a ray reflected on it
    :mirror => "M80-240L880-240L880-120L80-120ZM182.7-853L480-429.6L668.1-697.5L733.6-651.5L480-290.4L117.3-807ZM810-830L784.2-567.1L571.4-716.5Z",
    # own design: sensor with 2 × 2 pixels
    :detector => "M120-840L840-840L840-120L120-120ZM200-200L760-200L760-760L200-760ZM280-680L440-680L440-520L280-520ZM520-680L680-680L680-520L520-520ZM280-440L440-440L440-280L280-280ZM520-440L680-440L680-280L520-280Z",
    # own design: laser head emitting a beam
    :source => "M80-700L500-700L500-260L80-260ZM160-340L420-340L420-620L160-620ZM500-520L720-520L720-440L500-440ZM880-480L680-310L680-650Z",
    # own design: beamsplitter cube with its diagonal coating, an incoming ray from the left, the
    # transmitted ray to the right and the reflected ray upwards
    :beamsplitter => "M200-760L760-760L760-200L200-200ZM280-280L680-280L680-680L280-680ZM280-336.6L623.4-680L680-680L680-623.4L336.6-280L280-280ZM40-520L200-520L200-440L40-440ZM760-520L920-520L920-440L760-440ZM440-920L520-920L520-760L440-760Z",
    # own design: polarizer disc with its transmission axis
    :polarizer => "M480-840C678.8-840 840-678.8 840-480C840-281.2 678.8-120 480-120C281.2-120 120-281.2 120-480C120-678.8 281.2-840 480-840ZM480-760C325.4-760 200-634.6 200-480C200-325.4 325.4-200 480-200C634.6-200 760-325.4 760-480C760-634.6 634.6-760 480-760ZM440-920L520-920L520-40L440-40Z",
    # own design: plane in perspective with its normal
    :clip_plane => "M80-120L300-400L880-400L660-120ZM625-180L745-340L335-340L215-180ZM440-670L520-670L520-260L440-260ZM480-880L630-650L330-650Z",
    # own design: bar chart, the icon of the tabs of `add_panel!`
    :chart => "M120-120V-840H200V-200H840V-120ZM280-280V-560H400V-280ZM480-280V-760H600V-280ZM680-280V-480H800V-280Z",
    # own design: a window open at its top right corner and an arrow out of it, i.e. a card that
    # leaves the sidebar and floats in the 3D view
    :float => "M120-840L200-840L200-120L120-120ZM120-200L840-200L840-120L120-120ZM120-840L480-840L480-760L120-760ZM760-480L840-480L840-120L760-120ZM560-840L840-840L840-760L560-760ZM760-840L840-840L840-560L760-560ZM371.7-428.3L771.7-828.3L828.3-771.7L428.3-371.7Z",
    # own design: a window with a sidebar at the right and an arrow into it, i.e. a card that goes
    # back into the sidebar
    :dock => "M120-840L840-840L840-120L120-120ZM200-200L760-200L760-760L200-760ZM560-760L640-760L640-200L560-200ZM220-520L400-520L400-440L220-440ZM360-620L500-480L360-340Z",
    # own design: breadboard with mounting holes, i.e. an optical system
    :system => "M80-760H880V-200H80ZM160-680V-280H800V-680ZM355-560C355-529.6 330.4-505 300-505C269.6-505 245-529.6 245-560C245-590.4 269.6-615 300-615C330.4-615 355-590.4 355-560ZM535-560C535-529.6 510.4-505 480-505C449.6-505 425-529.6 425-560C425-590.4 449.6-615 480-615C510.4-615 535-590.4 535-560ZM715-560C715-529.6 690.4-505 660-505C629.6-505 605-529.6 605-560C605-590.4 629.6-615 660-615C690.4-615 715-590.4 715-560ZM355-400C355-369.6 330.4-345 300-345C269.6-345 245-369.6 245-400C245-430.4 269.6-455 300-455C330.4-455 355-430.4 355-400ZM535-400C535-369.6 510.4-345 480-345C449.6-345 425-369.6 425-400C425-430.4 449.6-455 480-455C510.4-455 535-430.4 535-400ZM715-400C715-369.6 690.4-345 660-345C629.6-345 605-369.6 605-400C605-430.4 629.6-455 660-455C690.4-455 715-430.4 715-400Z",
    # more_horiz, search, tune: the tool rail of the compact layout, see `LiveOverlay.jl`
    # more_horiz
    :close => "m256-200-56-56 224-224-224-224 56-56 224 224 224-224 56 56-224 224 224 224-56 56-224-224-224 224Z",
    :more => "M240-400q-33 0-56.5-23.5T160-480q0-33 23.5-56.5T240-560q33 0 56.5 23.5T320-480q0 33-23.5 56.5T240-400Zm240 0q-33 0-56.5-23.5T400-480q0-33 23.5-56.5T480-560q33 0 56.5 23.5T560-480q0 33-23.5 56.5T480-400Zm240 0q-33 0-56.5-23.5T640-480q0-33 23.5-56.5T720-560q33 0 56.5 23.5T800-480q0 33-23.5 56.5T720-400Z",
    # search
    :search => "M784-120 532-372q-30 24-69 38t-83 14q-109 0-184.5-75.5T120-580q0-109 75.5-184.5T380-840q109 0 184.5 75.5T640-580q0 44-14 83t-38 69l252 252-56 56ZM380-400q75 0 127.5-52.5T560-580q0-75-52.5-127.5T380-760q-75 0-127.5 52.5T200-580q0 75 52.5 127.5T380-400Z",
    # tune
    :tune => "M440-120v-240h80v80h320v80H520v80h-80Zm-320-80v-80h240v80H120Zm160-160v-80H120v-80h160v-80h80v240h-80Zm160-80v-80h400v80H440Zm160-160v-240h80v80h160v80H680v80h-80Zm-480-80v-80h400v80H120Z",
    # catalog: the entries of the component catalog, own designs as above. Side view with the
    # optical axis horizontal and the light from the left, unless noted
    # own design: thin biconvex lens, solid, with the optical axis on both sides
    :thin_lens => "M480-900C511.4-830 533.6-760 548.3-690C562.9-620 570-550 570-480C570-410 562.9-340 548.3-270C533.6-200 511.4-130 480-60C448.6-130 426.4-200 411.7-270C397.1-340 390-410 390-480C390-550 397.1-620 411.7-690C426.4-760 448.6-830 480-900ZM60-520L330-520L330-440L60-440ZM630-520L900-520L900-440L630-440Z",
    # own design: thick biconvex lens with flat edges, without the optical axis
    :singlet => "M360-880L600-880C663.5-813.3 699.9-746.7 724.4-680C748.9-613.3 760-546.7 760-480C760-413.3 748.9-346.7 724.4-280C699.9-213.3 663.5-146.7 600-80L360-80C296.5-146.7 260.1-213.3 235.6-280C211.1-346.7 200-413.3 200-480C200-546.7 211.1-613.3 235.6-680C260.1-746.7 296.5-813.3 360-880ZM395.8-800C351.4-746.7 324.3-693.3 306.3-640C288.3-586.7 280-533.3 280-480C280-426.7 288.3-373.3 306.3-320C324.3-266.7 351.4-213.3 395.8-160L564.2-160C608.6-213.3 635.7-266.7 653.7-320C671.7-373.3 680-426.7 680-480C680-533.3 671.7-586.7 653.7-640C635.7-693.3 608.6-746.7 564.2-800Z",
    # own design: two cemented lenses, a biconvex one and a meniscus
    :doublet => "M270-880L730-880C761.6-813.3 783.7-746.7 798.3-680C812.9-613.3 820-546.7 820-480C820-413.3 812.9-346.7 798.3-280C783.7-213.3 761.6-146.7 730-80L270-80C221.5-146.7 190.6-213.3 170.1-280C149.6-346.7 140-413.3 140-480C140-546.7 149.6-613.3 170.1-680C190.6-746.7 221.5-813.3 270-880ZM312.4-800C278.8-746.7 256.5-693.3 241.7-640C227-586.7 220-533.3 220-480C220-426.7 227-373.3 241.7-320C256.5-266.7 278.8-213.3 312.4-160L408.7-160C450.9-213.3 477.1-266.7 494.5-320C512-373.3 520-426.7 520-480C520-533.3 512-586.7 494.5-640C477.1-693.3 450.9-746.7 408.7-800ZM506.7-800C540.7-746.7 563.2-693.3 578.1-640C593-586.7 600-533.3 600-480C600-426.7 593-373.3 578.1-320C563.2-266.7 540.7-213.3 506.7-160L677.8-160C699.3-213.3 714.7-266.7 724.9-320C735-373.3 740-426.7 740-480C740-533.3 735-586.7 724.9-640C714.7-693.3 699.3-746.7 677.8-800Z",
    # own design: three cemented lenses: biconvex, biconcave, biconvex
    :triplet => "M180-880L780-880C807.8-813.3 827.5-746.7 840.6-680C853.7-613.3 860-546.7 860-480C860-413.3 853.7-346.7 840.6-280C827.5-213.3 807.8-146.7 780-80L180-80C152.2-146.7 132.5-213.3 119.4-280C106.3-346.7 100-413.3 100-480C100-546.7 106.3-613.3 119.4-680C132.5-746.7 152.2-813.3 180-880ZM234.9-800C216-746.7 202.4-693.3 193.4-640C184.4-586.7 180-533.3 180-480C180-426.7 184.4-373.3 193.4-320C202.4-266.7 216-213.3 234.9-160L267.4-160C278.4-213.3 286.5-266.7 291.9-320C297.3-373.3 300-426.7 300-480C300-533.3 297.3-586.7 291.9-640C286.5-693.3 278.4-746.7 267.4-800ZM349-800C359.4-746.7 367.1-693.3 372.3-640C377.4-586.7 380-533.3 380-480C380-426.7 377.4-373.3 372.3-320C367.1-266.7 359.4-213.3 349-160L611-160C600.6-213.3 592.9-266.7 587.7-320C582.6-373.3 580-426.7 580-480C580-533.3 582.6-586.7 587.7-640C592.9-693.3 600.6-746.7 611-800ZM692.6-800C681.6-746.7 673.5-693.3 668.1-640C662.7-586.7 660-533.3 660-480C660-426.7 662.7-373.3 668.1-320C673.5-266.7 681.6-213.3 692.6-160L725.1-160C744-213.3 757.6-266.7 766.6-320C775.6-373.3 780-426.7 780-480C780-533.3 775.6-586.7 766.6-640C757.6-693.3 744-746.7 725.1-800Z",
    # own design: round mirror seen at an angle: its face and its solid edge
    :round_mirror => "M420-880L540-880C678.1-880 790-700.9 790-480C790-259.1 678.1-80 540-80L420-80C281.9-80 170-259.1 170-480C170-700.9 281.9-880 420-880ZM710-480C710-656.7 633.9-800 540-800C446.1-800 370-656.7 370-480C370-303.3 446.1-160 540-160C633.9-160 710-303.3 710-480Z",
    # own design: square mirror seen at an angle: its face and its solid edges
    :square_mirror => "M290-120L170-180L170-720L670-840L790-780L790-240ZM370-596.9L370-221.5L710-303.1L710-678.5Z",
    # own design: wide rectangular mirror seen at an angle: its face and its solid edges
    :rect_mirror => "M230-220L110-280L110-620L730-740L850-680L850-340ZM310-494L310-317L770-406L770-583Z",
    # own design: square mirror without thickness seen at an angle
    :thin_mirror => "M190-710L770-850L770-250L190-110ZM270-647L270-211.6L690-313L690-748.4Z",
    # own design: right-angle prism with its hypotenuse as a thick mirror, a ray reflected on it
    :prism_mirror => "M120-120L120-880L880-120ZM520-900L600-900L600-480L800-480L800-400L600-400L520-480ZM920-440L780-330L780-550ZM200-200L573.7-200L200-573.7Z",
    # own design: two mirrors at a right angle, a ray that goes in and comes back parallel
    :retroreflector => "M360-880L473.1-880L873.1-480L473.1-80L360-80L760-480ZM60-700L620-700L620-260L200-260L200-340L540-340L540-620L60-620ZM60-300L220-410L220-190Z",
    # own design: concave mirror in section: circular front, flat back
    :spherical_mirror => "M305-880L655-880L655-80L305-80C410.1-146.7 449.6-213.3 480.7-280C511.8-346.7 525-413.3 525-480C525-546.7 511.8-613.3 480.7-680C449.6-746.7 410.1-813.3 305-880Z",
    # own design: deep concave mirror in section, two parallel rays reflected into its focus
    :parabolic_mirror => "M537.8-880L860-880L860-80L537.8-80C611.9-146.7 667.4-213.3 704.4-280C741.5-346.7 760-413.3 760-480C760-546.7 741.5-613.3 704.4-680C667.4-746.7 611.9-813.3 537.8-880ZM60-750L712-750L712-670L60-670ZM60-290L712-290L712-210L60-210ZM653.9-727.3L726.1-692.7L616.1-462.7L543.9-497.3ZM726.1-267.3L653.9-232.7L543.9-462.7L616.1-497.3ZM620-480C620-457.9 602.1-440 580-440C557.9-440 540-457.9 540-480C540-502.1 557.9-520 580-520C602.1-520 620-502.1 620-480Z",
    # own design: concave mirror in section with its axis and its marked vertex
    :conic_mirror => "M520-880L830-880L830-80L520-80C608.9-146.7 649.2-213.3 678.3-280C707.4-346.7 720-413.3 720-480C720-546.7 707.4-613.3 678.3-680C649.2-746.7 608.9-813.3 520-880ZM60-520L720-520L720-440L60-440ZM820-480C820-424.8 775.2-380 720-380C664.8-380 620-424.8 620-480C620-535.2 664.8-580 720-580C775.2-580 820-535.2 820-480Z",
    # own design: concave mirror in section with its two focal points
    :ellipsoidal_mirror => "M527.5-880L840-880L840-80L527.5-80C629.6-146.7 662.2-213.3 690.2-280C718.2-346.7 730-413.3 730-480C730-546.7 718.2-613.3 690.2-680C662.2-746.7 629.6-813.3 527.5-880ZM220-480C220-441.3 188.7-410 150-410C111.3-410 80-441.3 80-480C80-518.7 111.3-550 150-550C188.7-550 220-518.7 220-480ZM520-480C520-441.3 488.7-410 450-410C411.3-410 380-441.3 380-480C380-518.7 411.3-550 450-550C488.7-550 520-518.7 520-480Z",
    # own design: convex mirror in section with its focal point behind it
    :hyperbolic_mirror => "M360-880L430-880L430-80L360-80C310-146.7 272.5-213.3 247.5-280C222.5-346.7 210-413.3 210-480C210-546.7 222.5-613.3 247.5-680C272.5-746.7 310-813.3 360-880ZM770-480C770-441.3 738.7-410 700-410C661.3-410 630-441.3 630-480C630-518.7 661.3-550 700-550C738.7-550 770-518.7 770-480Z",
    # own design: segment of a concave mirror in section above its axis, a ray reflected into the focus on the axis
    :offaxis_parabolic_mirror => "M530-830L679.1-888.1L909.1-298.1L760-240C780.8-462 695.5-680.7 530-830ZM60-160L900-160L900-80L60-80ZM60-670L690-670L690-590L60-590ZM644-655.2L706-604.8L291-94.8L229-145.2Z",
    # own design: segment of a concave mirror in section above its axis, the vertex marked on the axis
    :offaxis_conic_mirror => "M530-830L679.1-888.1L909.1-298.1L760-240C780.8-462 695.5-680.7 530-830ZM60-160L900-160L900-80L60-80ZM880-120C880-75.8 844.2-40 800-40C755.8-40 720-75.8 720-120C720-164.2 755.8-200 800-200C844.2-200 880-164.2 880-120Z",
    # own design: segment of a concave mirror in section above its axis, the two focal points on the axis
    :offaxis_ellipsoidal_mirror => "M530-830L679.1-888.1L909.1-298.1L760-240C780.8-462 695.5-680.7 530-830ZM60-160L900-160L900-80L60-80ZM280-120C280-75.8 244.2-40 200-40C155.8-40 120-75.8 120-120C120-164.2 155.8-200 200-200C244.2-200 280-164.2 280-120ZM580-120C580-75.8 544.2-40 500-40C455.8-40 420-75.8 420-120C420-164.2 455.8-200 500-200C544.2-200 580-164.2 580-120Z",
    # own design: segment of a convex mirror in section above its axis, the focal point behind it on the axis
    :offaxis_hyperbolic_mirror => "M430-830L508.8-798.2L278.8-228.2L200-260C179.4-476.1 265.2-688.7 430-830ZM60-160L900-160L900-80L60-80ZM820-120C820-75.8 784.2-40 740-40C695.8-40 660-75.8 660-120C660-164.2 695.8-200 740-200C784.2-200 820-164.2 820-120Z",
    # own design: thin plate under 45 degrees, an incoming ray from the left, the transmitted ray to the right and the reflected ray upwards
    :thin_beamsplitter => "M168.9-225.4L734.6-791.1L791.1-734.6L225.4-168.9ZM40-520L378.6-520L298.6-440L40-440ZM661.4-520L920-520L920-440L581.4-440ZM440-920L520-920L520-661.4L440-581.4Z",
    # own design: thin disc under 45 degrees seen at an angle, with the rays of the beamsplitter
    :round_thin_beamsplitter => "M777-777C827.8-726.2 735.9-552.1 571.9-388.1C407.9-224.1 233.8-132.2 183-183C132.2-233.8 224.1-407.9 388.1-571.9C552.1-735.9 726.2-827.8 777-777ZM40-520L251.3-520L171.3-440L40-440ZM788.7-520L920-520L920-440L708.7-440ZM440-920L520-920L520-788.7L440-708.7ZM720.4-720.4C700.9-739.9 577.4-648.1 444.6-515.4C311.9-382.6 220.1-259.1 239.6-239.6C259.1-220.1 382.6-311.9 515.4-444.6C648.1-577.4 739.9-700.9 720.4-720.4Z",
    # own design: thick plate under 45 degrees with the rays of the beamsplitter
    :plate_beamsplitter => "M119.4-274.9L685.1-840.6L840.6-685.1L274.9-119.4ZM40-520L279.6-520L199.6-440L40-440ZM760.4-520L920-520L920-440L680.4-440ZM440-920L520-920L520-760.4L440-680.4ZM232.5-274.9L274.9-232.5L727.5-685.1L685.1-727.5Z",
    # own design: thick disc under 45 degrees seen at an angle, with the rays of the beamsplitter
    :round_plate_beamsplitter => "M172.4-221.9C129.5-264.9 221.3-426.3 377.5-582.5C533.7-738.7 695.1-830.5 738.1-787.6L787.6-738.1C830.5-695.1 738.7-533.7 582.5-377.5C426.3-221.3 264.9-129.5 221.9-172.4ZM40-520L230.1-520L150.1-440L40-440ZM809.9-520L920-520L920-440L729.9-440ZM440-920L520-920L520-809.9L440-729.9ZM681.5-731C669.8-742.7 559-650.9 434-526C309.1-401 217.3-290.2 229-278.5C240.7-266.8 351.5-358.6 476.5-483.5C601.4-608.5 693.2-719.3 681.5-731Z",
    # own design: thick plate under 45 degrees, a ray that passes it with an offset
    :compensator => "M119.4-274.9L685.1-840.6L840.6-685.1L274.9-119.4ZM40-580L339.6-580L259.6-500L40-500ZM700.4-460L920-460L920-380L620.4-380ZM232.5-274.9L274.9-232.5L727.5-685.1L685.1-727.5Z",
    # own design: right-angle prism in section
    :prism => "M120-120L120-880L880-120ZM200-200L686.9-200L200-686.9Z",
    # own design: square polarizer with its transmission axis
    :polarization_filter => "M120-840L840-840L840-120L120-120ZM440-920L520-920L520-40L440-40ZM200-760L200-200L760-200L760-760Z",
    # own design: disc in section made of three layers, the optical axis on both sides
    :linear_polarizer => "M240-880L720-880L720-80L240-80ZM40-520L180-520L180-440L40-440ZM780-520L920-520L920-440L780-440ZM320-800L320-160L410-160L410-800ZM550-800L550-160L640-160L640-800Z",
)

const _SVG_TOKEN = r"[A-Za-z]|[-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?"

"""
    _svg_path(d::AbstractString; grid = 960)

Parses the SVG path data `d` on a `grid × grid` view box with the origin at the bottom left and y
down, i.e. `viewBox = "0 -grid grid grid"` as used by Material Symbols, into a `BezierPath` that
spans the unit square centered at the origin, y up. The view box, not the bounding box of the
path, is mapped to the unit square, such that all icons share the same scale and padding.

Supports the commands `M L H V Q T C S Z`, absolute and relative (no arcs); quadratic curves are
converted to cubic ones. Subpaths without a segment (`m…Z`, which Material Symbols use as a
placeholder) are dropped.
"""
function _svg_path(d::AbstractString; grid::Real = 960)
    tokens = [m.match for m in eachmatch(_SVG_TOKEN, d)]
    commands = Makie.PathCommand[]
    g = Float64(grid)
    tf(p) = Point2d(p[1] / g - 0.5, -p[2] / g - 0.5)
    cur = start = ctrl = Point2d(0, 0)
    cmd = prev = 'M'
    i = 1
    num() = (i += 1; parse(Float64, tokens[i - 1]))
    pt(rel) = (p = Point2d(num(), num()); rel ? cur + p : p)
    while i <= length(tokens)
        if isletter(tokens[i][1])
            cmd = tokens[i][1]
            i += 1
        end
        rel = islowercase(cmd)
        c = uppercase(cmd)
        if c == 'M'
            cur = start = pt(rel)
            push!(commands, MoveTo(tf(cur)))
            # further coordinate pairs are lines
            cmd = rel ? 'l' : 'L'
        elseif c == 'L'
            cur = pt(rel)
            push!(commands, LineTo(tf(cur)))
        elseif c == 'H'
            x = num()
            cur = Point2d(rel ? cur[1] + x : x, cur[2])
            push!(commands, LineTo(tf(cur)))
        elseif c == 'V'
            y = num()
            cur = Point2d(cur[1], rel ? cur[2] + y : y)
            push!(commands, LineTo(tf(cur)))
        elseif c == 'Q' || c == 'T'
            # T reflects the control point of a preceding quadratic curve
            q = c == 'Q' ? pt(rel) : (prev in ('Q', 'T') ? 2cur - ctrl : cur)
            p = pt(rel)
            push!(commands, CurveTo(tf(cur + 2 / 3 * (q - cur)), tf(p + 2 / 3 * (q - p)), tf(p)))
            ctrl, cur = q, p
        elseif c == 'C' || c == 'S'
            # S reflects the second control point of a preceding cubic curve
            c1 = c == 'C' ? pt(rel) : (prev in ('C', 'S') ? 2cur - ctrl : cur)
            c2 = pt(rel)
            p = pt(rel)
            push!(commands, CurveTo(tf(c1), tf(c2), tf(p)))
            ctrl, cur = c2, p
        elseif c == 'Z'
            if last(commands) isa MoveTo
                pop!(commands)
            else
                # An explicit line back to the start: Makie's bounding box of a path, which
                # scales the marker, misses the start of a subpath that is only reached by
                # `ClosePath`, e.g. the tip of an arrow head drawn from its tip
                cur == start || push!(commands, LineTo(tf(start)))
                push!(commands, ClosePath())
            end
            cur = start
        else
            throw(ArgumentError("SVG path command $cmd is not supported"))
        end
        prev = c
    end
    return BezierPath(commands)
end

# Parsed once, at precompile time
const _ICONS = Dict{Symbol, BezierPath}(name => _svg_path(d) for (name, d) in _ICON_SVG)

"""
    _icon(name::Symbol)
    _icon(path::BezierPath)

Returns the icon `name` as a `BezierPath` in the unit square centered at the origin, for use as a
`scatter` marker (`markersize` = size of the icon in pixels, with the usual padding of Material
Symbols). See `keys(_ICONS)` for the available names; `:object` is the generic icon of objects
without an own one. An own `path`, e.g. the icon of a tool of [`add_tool!`](@ref), is returned
as it is.
"""
function _icon(name::Symbol)
    haskey(_ICONS, name) && return _ICONS[name]
    throw(ArgumentError("Unknown icon :$name, available: $(join(sort!(collect(keys(_ICONS))), ", "))"))
end
_icon(path::BezierPath) = path

# Colors of the icon buttons for a light theme; the app layout passes the tokens of its theme
const _ICON_COLOR = RGBAf(0.23, 0.25, 0.29, 1)
const _ICON_HOVER_COLOR = RGBAf(0.1, 0.12, 0.16, 0.08)
const _ICON_ACTIVE_COLOR = RGBAf(0.16, 0.44, 0.9, 0.16)
const _ICON_ACTIVE_ICON_COLOR = RGBAf(0.09, 0.35, 0.78, 1)
const _TOOLTIP_COLOR = RGBAf(0.17, 0.18, 0.21, 0.96)
const _TOOLTIP_TEXT_COLOR = RGBAf(0.97, 0.97, 0.97, 1)
const _TRANSPARENT = RGBAf(0, 0, 0, 0)
# GLMakie draws the plots in the order of their z translation (clip range ±10000 of the pixel
# camera): the tooltip comes after the 3D view and the progress window (`_PROGRESS_Z`)
const _TOOLTIP_Z = 9000.0f0

"""
    _IconButton(parent; icon::Union{Symbol, BezierPath}, tooltip::String = "", size = 28, kwargs...)

A flat icon button of the app layout of the live view at the grid position `parent`, e.g.
`fig[1, 2]`: the icon [`_icon(icon)`](@ref _icon) on a transparent square of `size` pixels, which
gets a rounded background while the mouse is over it. A left click increments `clicks`, like
`Makie.Button`. The tooltip appears below the button after the mouse rests on it for
`tooltip_delay` seconds.

# Keyword arguments

- `icon_size = round(0.72 * size)`: size of the icon in pixels
- `icon_color`, `hover_color`, `active_color`, `active_icon_color`: colors of the theme, see
  `_ICON_COLOR` etc.; `active_*` are used by [`_IconToggle`](@ref) only
- `tooltip_color`, `tooltip_text_color`, `tooltip_placement = :below` (`:above`, `:left`,
  `:right`), `tooltip_delay = 0.5`
- further keyword arguments, e.g. `halign` or `tellwidth`, go to the `Makie.Box`

# Fields

- `box`: the `Makie.Box` that holds the layout and draws the background
- `clicks`: number of clicks
- `hovered`: whether the mouse is over the button
- `tooltip`: the text of the tooltip, may be changed
- `icon`, `icon_color`, `background`: the marker and the colors as drawn
- `plots`: background, icon and tooltip

Hover and clicks are handled by `Makie.addmouseevents!` on the bounding box: observables change
only when the mouse enters or leaves the button, there is no per-frame work.
"""
struct _IconButton
    box::Makie.Box
    clicks::Observable{Int}
    hovered::Observable{Bool}
    tooltip::Observable{String}
    icon::Observable{BezierPath}
    icon_color::Observable{RGBAf}
    background::Observable{RGBAf}
    plots::Vector{Makie.AbstractPlot}
end

"""
    _IconToggle(parent; icon::Union{Symbol, BezierPath}, icon_off = icon, tooltip::String = "",
                active = false, size = 28, kwargs...)

A flat icon toggle of the app layout of the live view, see [`_IconButton`](@ref) for the look and
the keyword arguments. A left click flips `active`, which can also be set from code, like
`Makie.Toggle.active`; `active` may be passed as an `Observable{Bool}`, which the toggle then uses.
While active, the toggle shows `icon` in `active_icon_color` on an `active_color` background,
otherwise `icon_off` in `icon_color`.

# Fields

As [`_IconButton`](@ref), with `active::Observable{Bool}` in place of `clicks`.
"""
struct _IconToggle
    box::Makie.Box
    active::Observable{Bool}
    hovered::Observable{Bool}
    tooltip::Observable{String}
    icon::Observable{BezierPath}
    icon_color::Observable{RGBAf}
    background::Observable{RGBAf}
    plots::Vector{Makie.AbstractPlot}
end

function _IconButton(parent; icon::Union{Symbol, BezierPath}, tooltip::String = "", kwargs...)
    clicks = Observable(0)
    w = _icon_widget(parent, Observable(_icon(icon)), Observable(false), tooltip,
        () -> (clicks[] += 1); kwargs...)
    return _IconButton(w.box, clicks, w.hovered, w.tooltip, w.icon, w.icon_color, w.background,
        w.plots)
end

function _IconToggle(parent; icon::Union{Symbol, BezierPath}, icon_off::Union{Symbol, BezierPath} = icon,
        tooltip::String = "", active = false, kwargs...)
    active = convert(Observable{Bool}, active)
    on_icon, off_icon = _icon(icon), _icon(icon_off)
    marker = lift(a -> a ? on_icon : off_icon, active)
    w = _icon_widget(parent, marker, active, tooltip, () -> (active[] = !active[]); kwargs...)
    return _IconToggle(w.box, active, w.hovered, w.tooltip, w.icon, w.icon_color, w.background,
        w.plots)
end

Base.delete!(b::Union{_IconButton, _IconToggle}) = delete!(b.box)

"""
    _icon_widget(parent, icon, active, tooltip, onclick; kwargs...)

Builds the plots and the mouse handling shared by [`_IconButton`](@ref) and
[`_IconToggle`](@ref); `onclick()` runs on a left click. Returns a `NamedTuple` of the fields.
"""
function _icon_widget(parent, icon::Observable{BezierPath}, active::Observable{Bool},
        tooltip::String, onclick;
        size::Real = 28, icon_size::Real = round(0.72 * size),
        icon_color = _ICON_COLOR, hover_color = _ICON_HOVER_COLOR,
        active_color = _ICON_ACTIVE_COLOR, active_icon_color = _ICON_ACTIVE_ICON_COLOR,
        tooltip_color = _TOOLTIP_COLOR, tooltip_text_color = _TOOLTIP_TEXT_COLOR,
        tooltip_placement::Symbol = :below, tooltip_delay::Real = 0.5, layout_kwargs...)
    c_icon, c_hover = RGBAf(Makie.to_color(icon_color)), RGBAf(Makie.to_color(hover_color))
    c_active = RGBAf(Makie.to_color(active_color))
    c_active_icon = RGBAf(Makie.to_color(active_icon_color))
    hovered = Observable(false)
    background = Observable(_TRANSPARENT)
    fg = Observable(c_icon)
    box = Makie.Box(parent; width = size, height = size, color = background,
        strokevisible = false, cornerradius = max(size / 6, 3), layout_kwargs...)
    scene = box.blockscene
    bg = only(scene.plots)
    bbox = box.layoutobservables.computedbbox
    # Only on changes of the state, not per mouse move
    function update_look!(_...)
        b = active[] ? c_active : hovered[] ? c_hover : _TRANSPARENT
        f = active[] ? c_active_icon : c_icon
        background[] == b || (background[] = b)
        fg[] == f || (fg[] = f)
        return nothing
    end
    onany(update_look!, scene, hovered, active)
    update_look!()
    center = lift(r -> Point2f(Makie.origin(r) .+ Makie.widths(r) ./ 2), scene, bbox)
    marker = scatter!(scene, center; marker = icon, markersize = icon_size, color = fg,
        markerspace = :pixel, visible = box.visible, inspectable = false)
    translate!(marker, 0, 0, 1)

    # Tooltip, placed when shown
    tip_text = Observable(tooltip)
    tip_visible = Observable(false)
    tip_pos = Observable(Point2f(0))
    tip_align = Observable(0.5f0)
    tip = Makie.tooltip!(scene, tip_pos, tip_text; placement = tooltip_placement,
        align = tip_align, visible = tip_visible, backgroundcolor = tooltip_color,
        textcolor = tooltip_text_color, outline_linewidth = 0, triangle_size = 6, offset = 4,
        fontsize = 13, textpadding = (6, 6, 4, 4), overdraw = true, inspectable = false)
    translate!(tip, 0, 0, _TOOLTIP_Z)
    function show_tooltip!()
        (hovered[] && !isempty(tip_text[])) || return nothing
        r = bbox[]
        (x0, y0), (w, h) = Makie.origin(r), Makie.widths(r)
        tip_pos[] = tooltip_placement === :below ? Point2f(x0 + w / 2, y0) :
                    tooltip_placement === :above ? Point2f(x0 + w / 2, y0 + h) :
                    tooltip_placement === :left ? Point2f(x0, y0 + h / 2) :
                    Point2f(x0 + w, y0 + h / 2)
        # Keep the tooltip of buttons near the left or right edge inside the window: `align` is
        # the position of the arrow along the tooltip, from the left
        if tooltip_placement in (:below, :above)
            W = Makie.widths(Makie.viewport(scene)[])[1]
            tip_align[] = x0 + w / 2 < W / 4 ? 0.15f0 : x0 + w / 2 > 3W / 4 ? 0.85f0 : 0.5f0
        end
        tip_visible[] = true
        return nothing
    end
    timer = Ref{Union{Nothing, Timer}}(nothing)
    function hide_tooltip!()
        isnothing(timer[]) || (close(timer[]); timer[] = nothing)
        tip_visible[] && (tip_visible[] = false)
        return nothing
    end

    mouse = Makie.addmouseevents!(scene, bbox)
    on(scene, mouse.obs) do event
        t = event.type
        if t === Makie.MouseEventTypes.enter && box.visible[]
            hovered[] = true
            if tooltip_delay > 0
                timer[] = Timer(_ -> show_tooltip!(), tooltip_delay)
            else
                show_tooltip!()
            end
        elseif t === Makie.MouseEventTypes.out
            hovered[] && (hovered[] = false)
            hide_tooltip!()
        elseif t in (Makie.MouseEventTypes.leftclick, Makie.MouseEventTypes.leftdoubleclick) &&
               box.visible[]
            # The second of two fast clicks is a double click, which counts as a click
            hide_tooltip!()
            onclick()
            return Consume(true)
        end
        return Consume(false)
    end
    plots = Makie.AbstractPlot[bg, marker, tip]
    return (; box, hovered, tooltip = tip_text, icon, icon_color = fg, background, plots)
end
