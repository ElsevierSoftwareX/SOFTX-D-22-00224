ms_superstructure=5;
/* Jacket joints */
Point(1)={5.48483,9.5,-0,ms_superstructure};
Point(2)={-10.9697,1.3434e-15,-0,ms_superstructure};
Point(3)={5.48483,-9.5,-0,ms_superstructure};
Point(4)={4.8331,8.37118,-12.0407,ms_superstructure};
Point(5)={-9.66621,1.18377e-15,-12.0407,ms_superstructure};
Point(6)={4.8331,-8.37118,-12.0407,ms_superstructure};
Point(7)={4.25882,7.3765,-22.6507,ms_superstructure};
Point(8)={-8.51764,1.04311e-15,-22.6507,ms_superstructure};
Point(9)={4.25882,-7.3765,-22.6507,ms_superstructure};
Point(10)={3.75278,6.5,-32,ms_superstructure};
Point(11)={-7.50555,9.19165e-16,-32,ms_superstructure};
Point(12)={3.75278,-6.5,-32,ms_superstructure};
Point(13)={-2.56919,4.44997,-6.40063,ms_superstructure};
Point(14)={-2.56919,-4.44997,-6.40063,ms_superstructure};
Point(15)={5.13838,-1.25854e-15,-6.40063,ms_superstructure};
Point(16)={-2.26391,3.92121,-17.6808,ms_superstructure};
Point(17)={-2.26391,-3.92121,-17.6808,ms_superstructure};
Point(18)={4.52783,-1.109e-15,-17.6808,ms_superstructure};
Point(19)={-1.99491,3.45528,-27.6206,ms_superstructure};
Point(20)={-1.99491,-3.45528,-27.6206,ms_superstructure};
Point(21)={3.98982,-9.77223e-16,-27.6206,ms_superstructure};
Point(22)={0,0,-27,ms_superstructure};
Point(23)={0,0,-32,ms_superstructure};
/* Jacket members */
Line(1)={1,4};
Line(2)={4,7};
Line(3)={7,10};
Line(4)={2,5};
Line(5)={5,8};
Line(6)={8,11};
Line(7)={3,6};
Line(8)={6,9};
Line(9)={9,12};
Physical Line("Jacket_member_type_2",2)={1,2,3,4,5,6,7,8,9};
Line(10)={1,13};
Line(11)={2,13};
Line(12)={4,13};
Line(13)={5,13};
Line(14)={2,14};
Line(15)={3,14};
Line(16)={5,14};
Line(17)={6,14};
Line(18)={3,15};
Line(19)={1,15};
Line(20)={6,15};
Line(21)={4,15};
Physical Line("Jacket_member_type_3",3)={10,11,12,13,14,15,16,17,18,19,20,21};
Line(22)={4,16};
Line(23)={5,16};
Line(24)={7,16};
Line(25)={8,16};
Line(26)={5,17};
Line(27)={6,17};
Line(28)={8,17};
Line(29)={9,17};
Line(30)={6,18};
Line(31)={4,18};
Line(32)={9,18};
Line(33)={7,18};
Physical Line("Jacket_member_type_4",4)={22,23,24,25,26,27,28,29,30,31,32,33};
Line(34)={7,19};
Line(35)={8,19};
Line(36)={10,19};
Line(37)={11,19};
Line(38)={8,20};
Line(39)={9,20};
Line(40)={11,20};
Line(41)={12,20};
Line(42)={9,21};
Line(43)={7,21};
Line(44)={12,21};
Line(45)={10,21};
Physical Line("Jacket_member_type_5",5)={34,35,36,37,38,39,40,41,42,43,44,45};
/* Transition piece */
Point (24)={0,0,-45,ms_superstructure};
Point (25)={-1.87639,3.25,-32,ms_superstructure};
Point (26)={-1.87639,-3.25,-32,ms_superstructure};
Point (27)={3.75278,0,-32,ms_superstructure};
Line(46)={10,25};
Line(47)={25,11};
Line(48)={11,26};
Line(49)={26,12};
Line(50)={12,27};
Line(51)={27,10};
Line(52)={25,23};
Line(53)={26,23};
Line(54)={27,23};
Transfinite Line {46,47,48,49,50,51,52,53,54}=2+1;
Line Loop(1)={46,52,-54,51};
Line Loop(2)={48,53,-52,47};
Line Loop(3)={50,54,-53,49};
Plane Surface(1)={1};
Plane Surface(2)={2};
Plane Surface(3)={3};
Transfinite Surface {1,2,3};
Recombine Surface {1,2,3};
Physical Surface("Transition_piece_plate",6)={1,2,3};
Line(55)={10,24};
Line(56)={11,24};
Line(57)={12,24};
Physical Line("Transition_piece_members",7)={55,56,57};
/* Tower */
Line(58)={23,24};
Physical Line("Tower_1",8)={58};
Point (28)={0,0,-49.4167,ms_superstructure};
Line(59)={24,28};
Physical Line("Tower_2",9)={59};
Point (29)={0,0,-53.8333,ms_superstructure};
Line(60)={28,29};
Physical Line("Tower_3",10)={60};
Point (30)={0,0,-58.25,ms_superstructure};
Line(61)={29,30};
Physical Line("Tower_4",11)={61};
Point (31)={0,0,-62.6667,ms_superstructure};
Line(62)={30,31};
Physical Line("Tower_5",12)={62};
Point (32)={0,0,-67.0833,ms_superstructure};
Line(63)={31,32};
Physical Line("Tower_6",13)={63};
Point (33)={0,0,-71.5,ms_superstructure};
Line(64)={32,33};
Physical Line("Tower_7",14)={64};
Point (34)={0,0,-75.9167,ms_superstructure};
Line(65)={33,34};
Physical Line("Tower_8",15)={65};
Point (35)={0,0,-80.3333,ms_superstructure};
Line(66)={34,35};
Physical Line("Tower_9",16)={66};
Point (36)={0,0,-84.75,ms_superstructure};
Line(67)={35,36};
Physical Line("Tower_10",17)={67};
Point (37)={0,0,-89.1667,ms_superstructure};
Line(68)={36,37};
Physical Line("Tower_11",18)={68};
Point (38)={0,0,-93.5833,ms_superstructure};
Line(69)={37,38};
Physical Line("Tower_12",19)={69};
Point (39)={0,0,-98,ms_superstructure};
Line(70)={38,39};
Physical Line("Tower_13",20)={70};
Point (40)={0,0,-102.417,ms_superstructure};
Line(71)={39,40};
Physical Line("Tower_14",21)={71};
Point (41)={0,0,-106.833,ms_superstructure};
Line(72)={40,41};
Physical Line("Tower_15",22)={72};
Point (42)={0,0,-111.25,ms_superstructure};
Line(73)={41,42};
Physical Line("Tower_16",23)={73};
Point (43)={0,0,-115.667,ms_superstructure};
Line(74)={42,43};
Physical Line("Tower_17",24)={74};
Point (44)={0,0,-120.083,ms_superstructure};
Line(75)={43,44};
Physical Line("Tower_18",25)={75};
Point (45)={0,0,-124.5,ms_superstructure};
Line(76)={44,45};
Physical Line("Tower_19",26)={76};
Point (46)={0,0,-128.917,ms_superstructure};
Line(77)={45,46};
Physical Line("Tower_20",27)={77};
Point (47)={0,0,-133.333,ms_superstructure};
Line(78)={46,47};
Physical Line("Tower_21",28)={78};
Point (48)={0,0,-137.75,ms_superstructure};
Line(79)={47,48};
Physical Line("Tower_22",29)={79};
Point (49)={0,0,-142.167,ms_superstructure};
Line(80)={48,49};
Physical Line("Tower_23",30)={80};
Point (50)={0,0,-146.583,ms_superstructure};
Line(81)={49,50};
Physical Line("Tower_24",31)={81};
Point (51)={0,0,-151,ms_superstructure};
Line(82)={50,51};
Physical Line("Tower_25",32)={82};
Physical Point("RNA",33)={51};
/* Foundation: shell-soil model */
ms_foundation=3;
ms_far=10;
Include "Bucket.geo";
Include "SoilLid.geo";
Include "SoilSkirt.geo";
L=7.57;
D=7.57;
idlid=34;
idskirt=35;
idboundary=36;
idbodyload=37;
Physical Surface ("foundation_lid",idlid) = {};
Physical Surface ("foundation_skirt",idskirt) = {};
Physical Surface ("soil-foundation_lid",idboundary) = {};
Physical Surface ("soil-foundation_skirt",idbodyload) = {};
idpc=1;
xc=5.48483;
yc=9.5;
zc=0;
Call Bucket;
Call SoilLid;
Call SoilSkirt;
idpc=2;
xc=-10.9697;
yc=1.3434e-15;
zc=0;
Call Bucket;
Call SoilLid;
Call SoilSkirt;
idpc=3;
xc=5.48483;
yc=-9.5;
zc=0;
Call Bucket;
Call SoilLid;
Call SoilSkirt;
/* Free Surface */
Include "FreeSurface.geo";
idfreesurface=38;
zc=0;
// Hole bucket 1
xc=5.48483;
yc=9.5;
Call FreeSurface;
// Hole bucket 2
xc=-10.9697;
yc=0;
Call FreeSurface;
// Hole bucket 3
xc= 5.48483;
yc=-9.5;
Call FreeSurface;
// Free Surface
R=50;
poc=newp; Point(poc)={0,0,0,ms_foundation};
po1=newp; Point(po1)={R,0,0,ms_far};
po2=newp; Point(po2)={0,R,0,ms_far};
po3=newp; Point(po3)={-R,0,0,ms_far};
po4=newp; Point(po4)={0,-R,0,ms_far};
li1=newl; Circle(li1)={po1,poc,po2};
li2=newl; Circle(li2)={po2,poc,po3};
li3=newl; Circle(li3)={po3,poc,po4};
li4=newl; Circle(li4)={po4,poc,po1};
ll1=newll; Line Loop(ll1 )={li1,li2,li3,li4};
ss1 =news; Plane Surface(ss1 ) = {-ll1,-(ll1-5),-(ll1-14),-(ll1-23)};
Physical Surface ("free-surface",idfreesurface) = {ss1};

Mesh.Algorithm=6;
