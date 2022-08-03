! ---------------------------------------------------------------------
! Copyright (C) 2014-2022 Universidad de Las Palmas de Gran Canaria:
!                         Jacob D.R. Bordon
!                         Guillermo M. Alamo
!                         Juan J. Aznarez
!                         Orlando Maeso.
!
! This program is free software: you can redistribute it and/or modify
! it under the terms of the GNU General Public License as published by
! the Free Software Foundation, either version 2 of the License, or
! (at your option) any later version.
!
! This program is distributed in the hope that it will be useful,
! but WITHOUT ANY WARRANTY; without even the implied warranty of
! MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
! GNU General Public License for more details.
!
! You should have received a copy of the GNU General Public License
! along with this program.  If not, see <http://www.gnu.org/licenses/>.
! ---------------------------------------------------------------------

!! @author Jacob David Rodriguez Bordon (jacobdavid.rodriguezbordon@ulpgc.es)
!!
!! @version 2.0
!!
!! <b> This module implements shell finite elements </b>
module fbem_fem_shells

  ! Fortran 2003 standard
  use iso_fortran_env

  ! fbem modules
  use fbem_numerical
  use fbem_quad_rules
  use fbem_string_handling
  use fbem_shape_functions
  use fbem_geometry

  ! No implicit variables are allowed in the module
  implicit none

  ! By default all are private
  private

  ! ================================================================================================================================
  !
  ! 3D SHELL FINITE ELEMENTS (DEGENERATED FROM THREE-DIMENSIONAL SOLIDS)
  !
  ! The mid-plane discretization could be one of the general elements in fbem_shape_functions module. The thickness direction is
  ! linearly interpolated.
  !
  ! Each element needs:
  !   - Element type: tri3, tri6, quad4, quad8, quad9
  !   - Position vectors of the mid-plane nodes.
  !   - Local axes for each mid-node for the rotation degrees of freedom.
  !   - Thickness of each node.
  !   - Region properties.
  !   - Number of Gauss of integration points for in-plane coordinates (xi1,xi2) for both the membrane-bending and the shear local strain
  !     contributions, and thickness coordinate (xi3).
  !
  ! Bibliography:
  !   - K.J. Bathe, Finite Element Procedures, 1996.
  !   - O.C. Zienkiewicz and R.L. Taylor, The Finite Element Method, Volume 2 - Solid Mechanics, 5th edition, 2000.
  !   - E. Oñate, Structural Analysis with Finite Element Method, Volume 2 - Beams, Plates and Shells, 1st edition, 2013.
  !
  public :: fbem_fem_degshell_K_static
  public :: fbem_fem_degshell_K_harmonic
  public :: fbem_fem_degshell_Q_midsurface
  public :: fbem_fem_degshell_L_load
  !
  public :: fbem_fem_degshell_x           ! Position vector at a local coordinate
  public :: fbem_fem_degshell_Lci         ! Calculate the coordinate transformation matrix Lc^(i) for each node
  public :: fbem_fem_degshell_Lc          ! Coordinate transformation matrix Lc
  public :: fbem_fem_degshell_Lc_enlarged ! Coordinate transformation matrix Lc enlarged
  public :: fbem_fem_degshell_N           ! Displacement shape function matrix N at a givel local coordinate (5 DOF for each node)
  public :: fbem_fem_degshell_Ni          ! Displacements shape functions matrix N^(i) at a givel local coordinate (5 DOF for each node)
  public :: fbem_fem_degshell_K_real      ! Stiffness matrix K (static, with real elastic constants)
  public :: fbem_fem_degshell_K_ot_real   ! Stiffness matrix K (static, orthotropic, with real elastic constants)
  public :: fbem_fem_mitcdegshell_K_real
  !
  public :: fbem_fem_degshell_M           ! Mass matrix M (to be deprecated and subtituted by Qbody)
  public :: fbem_fem_degshell_Q           ! Load matrix Q for a mid-plane distributed load (global coordinates load / global disp., local rot.)
  public :: fbem_fem_degshell_Q_face      ! Load matrix Q face distributed load (global coordinates load / global disp., local rot.)
  public :: fbem_fem_degshell_Q_edge      ! Load matrix Q^edge for an edge distributed load (global coordinates load / global disp., local rot.)
  public :: fbem_fem_degshell_Ld          ! Transformation matrix Ld for local to global distributed load (on mid-plane)
  !
  public :: fbem_fem_degshell_stress_resultants
  public :: fbem_fem_degshell_stress_resultants_ep
  public :: fbem_fem_degshell_stress_tensor
  ! ================================================================================================================================

contains

  subroutine fbem_fem_degshell_K_static(etype,mitc,x_md,v_md,t_md,ndof_md,Em,nu,kappa,intmode,ngp,K)
    implicit none
    ! I/O
    integer           :: etype                                          !! Type of element (displacements interpolation): tri3, tri6, quad4, quad8, quad9.
    logical           :: mitc                                           !! Use MITC elements
    real(kind=real64) :: x_md(3,fbem_n_nodes(etype))                    !! Position vectors of the mid-plane nodes.
    real(kind=real64) :: v_md(3,3,fbem_n_nodes(etype))                  !! Local axes for each mid-node for the rotation degrees of freedom.
    real(kind=real64) :: t_md(3,fbem_n_nodes(etype))                    !! Thickness of each mid-node in the v_3 direction.
    integer           :: ndof_md(fbem_n_nodes(etype))                   !! Number of DOF for each node: 5 (local rotations) or 6 (global rotations).
    real(kind=real64) :: Em                                             !! Young's modulus
    real(kind=real64) :: nu                                             !! Poisson's ratio
    real(kind=real64) :: kappa(3)                                       !! Shear correction factors: kx', ky',-
    integer           :: intmode                                        !! Integration mode: 0 (full), (1) reduced, (2) selective, (3) user-defined
    integer           :: ngp(3)                                         !! Number of integration points for user-defined mode: (1) membrane, (2) shear (3) thickness
    real(kind=real64) :: K(6*fbem_n_nodes(etype),6*fbem_n_nodes(etype)) !! Stiffness matrix
    ! Local
    integer                        :: n_midnodes      !! Number of mid-nodes
    integer                        :: kn
    integer                        :: ndof_element
    integer                        :: gln_kip         !! Number of Gauss-Legendre integration points for in-plane coordinates (xi1,xi2) for the membrane-bending (inplane) local strain contribution.
    integer                        :: gln_ksh         !! Number of Gauss-Legendre integration points for in-plane coordinates (xi1,xi2) for the shear local strain contribution.
    integer                        :: gln_kth         !! Number of Gauss-Legendre integration points for thickness coordinate (xi3)
    real(kind=real64)              :: t3_md(fbem_n_nodes(etype))
    real(kind=real64), allocatable :: Lc(:,:)
    real(kind=real64), allocatable :: Kp(:,:)
    real(kind=real64), allocatable :: Kf(:,:)
    real(kind=real64)              :: V               !! Volume of the element
    integer                        :: kni, knj
    integer                        :: kdofei, kdofej
    integer                        :: kis, kie
    integer                        :: kjs, kje
    !
    ! Initialization and checkings
    !
    n_midnodes=fbem_n_nodes(etype)
    do kn=1,n_midnodes
      if ((ndof_md(kn).ne.5).and.(ndof_md(kn).ne.6)) then
        call fbem_error_message(error_unit,0,__FILE__,__LINE__,'degshell nodes must have 5 or 6 DOF')
      end if
    end do
    ndof_element=sum(ndof_md)
    t3_md=t_md(3,:)
    !
    ! Integration mode
    !
    select case (intmode)
      ! Full integration
      case (0)
        select case (etype)
          case (fbem_tri3,fbem_quad4)
            gln_kip=2
            gln_ksh=2
            gln_kth=2
          case (fbem_tri6,fbem_quad8,fbem_quad9)
            gln_kip=3
            gln_ksh=3
            gln_kth=2
        end select
      ! Reduced integration
      case (1)
        select case (etype)
          case (fbem_tri3,fbem_quad4)
            gln_kip=1
            gln_ksh=1
            gln_kth=2
          case (fbem_tri6,fbem_quad8,fbem_quad9)
            gln_kip=2
            gln_ksh=2
            gln_kth=2
        end select
      ! Selective integration
      case (2)
        select case (etype)
          case (fbem_tri3,fbem_quad4)
            gln_kip=2
            gln_ksh=1
            gln_kth=2
          case (fbem_tri6,fbem_quad8,fbem_quad9)
            gln_kip=3
            gln_ksh=2
            gln_kth=2
        end select
      ! User-defined integration
      case (3)
        gln_kip=ngp(1)
        gln_ksh=ngp(2)
        gln_kth=ngp(3)
      case default
        call fbem_error_message(error_unit,0,__FILE__,__LINE__,'invalid integration mode')
    end select
    !
    ! Calculate LOCAL STIFFNESS MATRIX (K')
    !
    allocate (Kp(5*n_midnodes,5*n_midnodes))
    if (mitc) then
      select case (etype)
        case (fbem_tri3,fbem_tri6,fbem_quad8)
          call fbem_fem_degshell_K_real(etype,x_md,v_md,t3_md,Em,nu,kappa,gln_kip,gln_ksh,gln_kth,Kp,V)
        case (fbem_quad4,fbem_quad9)
          ! Use full integration unless user-defined integration mode is selected
          if (intmode.ne.3) then
            select case (etype)
              case (fbem_tri3,fbem_quad4)
                gln_kip=2
                gln_ksh=2
                gln_kth=2
              case (fbem_tri6,fbem_quad8,fbem_quad9)
                gln_kip=3
                gln_ksh=3
                gln_kth=2
            end select
          end if
          call fbem_fem_mitcdegshell_K_real(etype,x_md,v_md,t3_md,Em,nu,kappa,gln_kip,gln_kth,Kp,V)
      end select
    else
      call fbem_fem_degshell_K_real(etype,x_md,v_md,t3_md,Em,nu,kappa,gln_kip,gln_ksh,gln_kth,Kp,V)
    end if
    !
    ! Add FICTICIOUS TORSIONAL STIFFNESS to 6 DOF nodes
    !
    allocate (Kf(ndof_element,ndof_element))
    Kf=0
    kdofei=0
    do kni=1,n_midnodes
      kis=kdofei+1
      kie=kdofei+5
      kdofej=0
      do knj=1,n_midnodes
        kjs=kdofej+1
        kje=kdofej+5
        Kf(kis:kie,kjs:kje)=Kp((5*kni-4):(5*kni),(5*knj-4):(5*knj))
        if ((kni.eq.knj).and.(ndof_md(kni).eq.6)) then
          !
          ! El ADINA (Bathe & cia) lo que hace es escog. la min. rigidez entre Kalpha y Kbeta y multiplicarla por 10^-4
          !
          ! !!! no se hemos probado
          !
          if (Kf(kie-1,kie-1).le.Kf(kie,kie)) then
            Kf(kie+1,kie+1)=1.d-4*Kf(kie-1,kie-1)
          else
            Kf(kie+1,kie+1)=1.d-4*Kf(kie,kie)
          end if
          !
          ! Usando el volumen (alguno de los articulos viejos de los 70s)
          !
          !Kf(kie+1,kie+1)=Em*V*1d-8
        end if
        kdofej=kdofej+ndof_md(knj)
      end do
      kdofei=kdofei+ndof_md(kni)
    end do
    !
    ! Calculate ENLARGED COORDINATE TRANSFORMATION MATRIX (Lc)
    !
    allocate (Lc(ndof_element,ndof_element))
    call fbem_fem_degshell_Lc_enlarged(etype,ndof_element,ndof_md,v_md,Lc)
    !
    ! Calculate and assemble GLOBAL STIFFNESS MATRIX (K)
    !
    Kf=matmul(Lc,matmul(Kf,transpose(Lc)))
    !
    ! Copy Kf to K
    !
    K=0
    K(1:ndof_element,1:ndof_element)=Kf
    !
    ! Finalization
    !
    deallocate (Kf,Kp,Lc)
  end subroutine fbem_fem_degshell_K_static

  subroutine fbem_fem_degshell_K_harmonic(omega,etype,mitc,x_md,v_md,t_md,ndof_md,Em,nu,kappa,rho,K_intmode,K_intngp,M_intmode,M_intngp,K)
    implicit none
    ! I/O
    real(kind=real64)    :: omega                                          !! Circular frequency
    integer              :: etype                                          !! Type of element (displacements interpolation): tri3, tri6, quad4, quad8, quad9.
    logical              :: mitc                                           !! Use MITC elements
    real(kind=real64)    :: x_md(3,fbem_n_nodes(etype))                    !! Position vectors of the mid-plane nodes.
    real(kind=real64)    :: v_md(3,3,fbem_n_nodes(etype))                  !! Local axes for each mid-node for the rotation degrees of freedom.
    real(kind=real64)    :: t_md(3,fbem_n_nodes(etype))                    !! Thickness of each mid-node in the v_3 direction.
    integer              :: ndof_md(fbem_n_nodes(etype))                   !! Number of DOF for each node: 5 (local rotations) or 6 (global rotations).
    complex(kind=real64) :: Em                                             !! Young's modulus
    real(kind=real64)    :: nu                                             !! Poisson's ratio
    real(kind=real64)    :: kappa(3)                                       !! Shear correction factors: kx', ky',-
    real(kind=real64)    :: rho                                            !! Density
    integer              :: K_intmode                                      !! Integration mode (K): 0 (full), (1) reduced, (2) selective, (3) user-defined
    integer              :: K_intngp(3)                                    !! Number of integration points for user-defined mode: (1) membrane, (2) shear (3) thickness
    integer              :: M_intmode                                      !! Integration mode (M): 0 (full), (1) reduced, (3) user-defined
    integer              :: M_intngp(3)                                    !! Number of integration points for user-defined mode (M): (1) line (2) thickness
    complex(kind=real64) :: K(6*fbem_n_nodes(etype),6*fbem_n_nodes(etype)) !! Stiffness matrix
    ! Local
    integer                           :: n_midnodes      !! Number of mid-nodes
    integer                           :: kn
    integer                           :: ndof_element
    integer                           :: gln_kip         !! Number of Gauss-Legendre integration points for in-plane coordinates (xi1,xi2) for the membrane-bending (inplane) local strain contribution.
    integer                           :: gln_ksh         !! Number of Gauss-Legendre integration points for in-plane coordinates (xi1,xi2) for the shear local strain contribution.
    integer                           :: gln_kth         !! Number of Gauss-Legendre integration points for thickness coordinate (xi3)
    real(kind=real64)                 :: t3_md(fbem_n_nodes(etype))
    real(kind=real64), allocatable    :: Lc(:,:)
    real(kind=real64), allocatable    :: Kp(:,:), Mp(:,:)
    complex(kind=real64), allocatable :: Kf(:,:)
    real(kind=real64)                 :: V               !! Volume of the element
    integer                           :: kni, knj
    integer                           :: kdofei, kdofej
    integer                           :: kis, kie
    integer                           :: kjs, kje
    !
    ! Initialization and checkings
    !
    n_midnodes=fbem_n_nodes(etype)
    do kn=1,n_midnodes
      if ((ndof_md(kn).ne.5).and.(ndof_md(kn).ne.6)) then
        call fbem_error_message(error_unit,0,__FILE__,__LINE__,'degshell nodes must have 5 or 6 DOF')
      end if
    end do
    ndof_element=sum(ndof_md)
    t3_md=t_md(3,:)
    !
    ! Integration mode (K)
    !
    select case (K_intmode)
      ! Full integration
      case (0)
        select case (etype)
          case (fbem_tri3,fbem_quad4)
            gln_kip=2
            gln_ksh=2
            gln_kth=2
          case (fbem_tri6,fbem_quad8,fbem_quad9)
            gln_kip=3
            gln_ksh=3
            gln_kth=2
        end select
      ! Reduced integration
      case (1)
        select case (etype)
          case (fbem_tri3,fbem_quad4)
            gln_kip=1
            gln_ksh=1
            gln_kth=2
          case (fbem_tri6,fbem_quad8,fbem_quad9)
            gln_kip=2
            gln_ksh=2
            gln_kth=2
        end select
      ! Selective integration
      case (2)
        select case (etype)
          case (fbem_tri3,fbem_quad4)
            gln_kip=2
            gln_ksh=1
            gln_kth=2
          case (fbem_tri6,fbem_quad8,fbem_quad9)
            gln_kip=3
            gln_ksh=2
            gln_kth=2
        end select
      ! User-defined integration
      case (3)
        gln_kip=K_intngp(1)
        gln_ksh=K_intngp(2)
        gln_kth=K_intngp(3)
      case default
        call fbem_error_message(error_unit,0,__FILE__,__LINE__,'invalid integration mode')
    end select
    !
    ! Calculate LOCAL STIFFNESS MATRIX (K') (with E=1)
    !
    allocate (Kp(5*n_midnodes,5*n_midnodes))
    if (mitc) then
      select case (etype)
        case (fbem_tri3,fbem_tri6,fbem_quad8)
          call fbem_fem_degshell_K_real(etype,x_md,v_md,t3_md,1.d0,nu,kappa,gln_kip,gln_ksh,gln_kth,Kp,V)
        case (fbem_quad4,fbem_quad9)
          ! Use full integration unless user-defined integration mode is selected
          if (K_intmode.ne.3) then
            select case (etype)
              case (fbem_tri3,fbem_quad4)
                gln_kip=2
                gln_ksh=2
                gln_kth=2
              case (fbem_tri6,fbem_quad8,fbem_quad9)
                gln_kip=3
                gln_ksh=3
                gln_kth=2
            end select
          end if
          call fbem_fem_mitcdegshell_K_real(etype,x_md,v_md,t3_md,1.d0,nu,kappa,gln_kip,gln_kth,Kp,V)
      end select
    else
      call fbem_fem_degshell_K_real(etype,x_md,v_md,t3_md,1.d0,nu,kappa,gln_kip,gln_ksh,gln_kth,Kp,V)
    end if
    !
    ! Add FICTICIOUS TORSIONAL STIFFNESS to 6 DOF nodes
    !
    allocate (Kf(ndof_element,ndof_element))
    Kf=0
    kdofei=0
    do kni=1,n_midnodes
      kis=kdofei+1
      kie=kdofei+5
      kdofej=0
      do knj=1,n_midnodes
        kjs=kdofej+1
        kje=kdofej+5
        Kf(kis:kie,kjs:kje)=Kp((5*kni-4):(5*kni),(5*knj-4):(5*knj))
        if ((kni.eq.knj).and.(ndof_md(kni).eq.6)) then
          !
          ! El ADINA (Bathe & cia) lo que hace es escog. la min. rigidez entre Kalpha y Kbeta y multiplicarla por 10^-4
          !
          ! !!! no se hemos probado
          !
          if (abs(Kf(kie-1,kie-1)).le.abs(Kf(kie,kie))) then
            Kf(kie+1,kie+1)=1.d-4*Kf(kie-1,kie-1)
          else
            Kf(kie+1,kie+1)=1.d-4*Kf(kie,kie)
          end if
          !
          ! Usando el volumen (alguno de los articulos viejos de los 70s)
          !
          !Kf(kie+1,kie+1)=Em*V*1d-8
        end if
        kdofej=kdofej+ndof_md(knj)
      end do
      kdofei=kdofei+ndof_md(kni)
    end do
    deallocate (Kp)
    !
    ! Multiply by the complex E
    !
    Kf=Em*Kf
    !
    ! Integration mode (M)
    !
    select case (M_intmode)
      ! Full integration
      case (0)
        select case (etype)
          case (fbem_tri3,fbem_quad4)
            gln_kip=2
            gln_ksh=2
            gln_kth=2
          case (fbem_tri6,fbem_quad8,fbem_quad9)
            gln_kip=3
            gln_ksh=3
            gln_kth=2
        end select
      ! Reduced integration
      case (1,2)
        select case (etype)
          case (fbem_tri3,fbem_quad4)
            gln_kip=1
            gln_ksh=1
            gln_kth=2
          case (fbem_tri6,fbem_quad8,fbem_quad9)
            gln_kip=2
            gln_ksh=2
            gln_kth=2
        end select
      ! User-defined integration
      case (3)
        gln_kip=M_intngp(1)
        gln_ksh=M_intngp(2)
        gln_kth=M_intngp(3)
      case default
        call fbem_error_message(error_unit,0,__FILE__,__LINE__,'invalid integration mode')
    end select
    !
    ! Calculate LOCAL MASS MATRIX (M')
    !
    allocate (Mp(5*n_midnodes,5*n_midnodes))
    call fbem_fem_degshell_M(etype,x_md,v_md,t3_md,rho,gln_kip,gln_kth,Mp)
    !
    ! Add TIME HARMONIC MASS MATRIX
    !
    kdofei=0
    do kni=1,n_midnodes
      kis=kdofei+1
      kie=kdofei+5
      kdofej=0
      do knj=1,n_midnodes
        kjs=kdofej+1
        kje=kdofej+5
        Kf(kis:kie,kjs:kje)=Kf(kis:kie,kjs:kje)-omega**2*Mp((5*kni-4):(5*kni),(5*knj-4):(5*knj))
        kdofej=kdofej+ndof_md(knj)
      end do
      kdofei=kdofei+ndof_md(kni)
    end do
    deallocate (Mp)
    !
    ! Calculate ENLARGED COORDINATE TRANSFORMATION MATRIX (Lc)
    !
    allocate (Lc(ndof_element,ndof_element))
    call fbem_fem_degshell_Lc_enlarged(etype,ndof_element,ndof_md,v_md,Lc)
    !
    ! Calculate and assemble GLOBAL STIFFNESS MATRIX (K)
    !
    Kf=matmul(Lc,matmul(Kf,transpose(Lc)))
    !
    ! Copy Kf to K
    !
    K=0
    K(1:ndof_element,1:ndof_element)=Kf
    !
    ! Finalization
    !
    deallocate (Kf,Lc)
  end subroutine fbem_fem_degshell_K_harmonic

  subroutine fbem_fem_degshell_Q_midsurface(etype,x_md,v_md,t_md,ndof_md,intmode,ngp,Q)
    implicit none
    ! I/O
    integer           :: etype                                          !! Type of element (displacements interpolation): tri3, tri6, quad4, quad8, quad9.
    real(kind=real64) :: x_md(3,fbem_n_nodes(etype))                    !! Position vectors of the mid-plane nodes.
    real(kind=real64) :: v_md(3,3,fbem_n_nodes(etype))                  !! Local axes for each mid-node for the rotation degrees of freedom.
    real(kind=real64) :: t_md(3,fbem_n_nodes(etype))                    !! Thickness of each mid-node in the v_3 direction.
    integer           :: ndof_md(fbem_n_nodes(etype))                   !! Number of DOF for each node: 5 (local rotations) or 6 (global rotations).
    integer           :: intmode                                        !! Integration mode: 0 (full), (1) reduced, (2) selective, (3) user-defined
    integer           :: ngp(3)                                         !! Number of integration points for user-defined mode: (1) membrane, (2) shear (3) thickness
    real(kind=real64) :: Q(6*fbem_n_nodes(etype),3*fbem_n_nodes(etype)) !! Equivalent load matrix
    ! Local
    integer                        :: n_midnodes
    integer                        :: kn
    integer                        :: ndof_element
    integer                        :: gln_kip
    real(kind=real64)              :: t3_md(fbem_n_nodes(etype))
    real(kind=real64), allocatable :: Lc(:,:)
    real(kind=real64), allocatable :: Qp(:,:)
    real(kind=real64), allocatable :: Qf(:,:)
    integer                        :: kni, knj
    integer                        :: kdofei, kdofej
    integer                        :: kis, kie
    integer                        :: kjs, kje
    !
    ! Initialization and checkings
    !
    n_midnodes=fbem_n_nodes(etype)
    do kn=1,n_midnodes
      if ((ndof_md(kn).ne.5).and.(ndof_md(kn).ne.6)) then
        call fbem_error_message(error_unit,0,__FILE__,__LINE__,'degshell nodes must have 5 or 6 DOF')
      end if
    end do
    ndof_element=sum(ndof_md)
    t3_md=t_md(3,:)
    !
    ! Integration mode
    !
    select case (intmode)
      ! Full integration
      case (0)
        select case (etype)
          case (fbem_tri3,fbem_quad4)
            gln_kip=2
          case (fbem_tri6,fbem_quad8,fbem_quad9)
            gln_kip=3
        end select
      ! Reduced integration
      case (1,2)
        select case (etype)
          case (fbem_tri3,fbem_quad4)
            gln_kip=1
          case (fbem_tri6,fbem_quad8,fbem_quad9)
            gln_kip=2
        end select
      ! User-defined integration
      case (3)
        gln_kip=ngp(1)
      case default
        call fbem_error_message(error_unit,0,__FILE__,__LINE__,'invalid integration mode')
    end select
    !
    ! Calculate LOAD MATRIX (Q'): DOF in local coordinates (global disp, local rotations) / load with global coordinates
    !
    allocate (Qp(5*n_midnodes,3*n_midnodes))
    call fbem_fem_degshell_Q_face(etype,x_md,v_md,t3_md,0,gln_kip,Qp)
    !
    ! Copy to Qf including 5 or 6 DOF nodes
    !
    allocate (Qf(ndof_element,3*n_midnodes))
    Qf=0
    kdofei=0
    do kni=1,n_midnodes
      kis=kdofei+1
      kie=kdofei+5
      kdofej=0
      do knj=1,n_midnodes
        kjs=kdofej+1
        kje=kdofej+3
        Qf(kis:kie,kjs:kje)=Qp((5*kni-4):(5*kni),(3*knj-2):(3*knj))
        kdofej=kdofej+3
      end do
      kdofei=kdofei+ndof_md(kni)
    end do
    !
    ! Calculate ENLARGED COORDINATE TRANSFORMATION MATRIX (Lc)
    !
    allocate (Lc(ndof_element,ndof_element))
    call fbem_fem_degshell_Lc_enlarged(etype,ndof_element,ndof_md,v_md,Lc)
    !
    ! Calculate and assemble GLOBAL STIFFNESS MATRIX (Qf)
    !
    Qf=matmul(Lc,Qf)
    !
    ! Copy Qf to Q
    !
    Q=0
    Q(1:ndof_element,1:3*n_midnodes)=Qf
    !
    ! Finalization
    !
    deallocate (Qf,Qp,Lc)
  end subroutine fbem_fem_degshell_Q_midsurface

  !! Calculate the position vector
  function fbem_fem_degshell_x(etype,x_md,v3_md,t_md,xi)
    implicit none
    ! I/O
    real(kind=real64) :: fbem_fem_degshell_x(3)         !! Position vector
    integer           :: etype                          !! Type of element (displacements interpolation): tri3, tri6, quad4, quad8, quad9.
    real(kind=real64) :: x_md(3,fbem_n_nodes(etype))    !! Position vectors of the mid-plane nodes.
    real(kind=real64) :: v3_md(3,fbem_n_nodes(etype))   !! Local axes for each mid-node for the rotation degrees of freedom.
    real(kind=real64) :: t_md(fbem_n_nodes(etype))      !! Thickness of each mid-node in the v_3 direction.
    real(kind=real64) :: xi(3)                          !! Local coordinate
    ! Local
    integer           :: n_md                           ! Number of mid-plane nodes
    integer           :: k                              ! Counter
    real(kind=real64) :: aux(10)                        ! Auxiliary variable needed for shape_functions module resources
    real(kind=real64) :: phi(fbem_n_nodes(etype))       ! phi shape functions
    real(kind=real64) :: varphi(fbem_n_nodes(etype))    ! varphi shape functions
    real(kind=real64) :: x(3)                           ! Position vector
    ! Number of nodes of the mid-plane element
    n_md=fbem_n_nodes(etype)
    ! Mid-plane shape functions
#   define delta 0.d0
#   include <phi_2d.rc>
#   undef delta
    ! Thickness shape function
    varphi=phi*0.5d0*xi(3)*t_md
    ! Calculate position vector x
    x=0.d0
    do k=1,n_md
      x=x+phi(k)*x_md(:,k)+varphi(k)*v3_md(:,k)
    end do
    fbem_fem_degshell_x=x
  end function fbem_fem_degshell_x

  !! Calculate the coordinate transformation matrix Lc^(i) for each node (local to global rotations, displacements are global).
  subroutine fbem_fem_degshell_Lci(etype,n_dof_node,v_md,Lci)
    implicit none
    ! I/O
    integer           :: etype                           !! Type of element (displacements interpolation): tri3, tri6, quad4, quad8, quad9.
    integer           :: n_dof_node(fbem_n_nodes(etype)) !! Number of DOF (5 (local rotations) or 6 (global rotations)) of each node
    real(kind=real64) :: v_md(3,3,fbem_n_nodes(etype))   !! Local axes for each mid-node for the rotation degrees of freedom.
    real(kind=real64) :: Lci(6,6,fbem_n_nodes(etype))    !! Coordinate transformation matrix. Transform all nodes with local rotations (5 DOF), to 5 or 6 DOF nodes: u=Lc·u' (u' is enlarged, i.e. dim(u')=dim(u))
    ! Local
    integer           :: n_nodes                         ! Number of nodes
    integer           :: kn                              ! Counter of nodes
    integer           :: n_dof                           ! Number of DOF
    ! Number of mid-plane nodes
    n_nodes=fbem_n_nodes(etype)
    ! Initialize
    Lci=0.d0
    ! Calculate
    do kn=1,n_nodes
      n_dof=n_dof_node(kn)
      Lci=0.d0
      select case (n_dof)
        case (5)
          Lci(1,1,kn)=1.d0
          Lci(2,2,kn)=1.d0
          Lci(3,3,kn)=1.d0
          Lci(4,4,kn)=1.d0
          Lci(5,5,kn)=1.d0
        case (6)
          Lci(1,1,kn)=1.d0
          Lci(2,2,kn)=1.d0
          Lci(3,3,kn)=1.d0
          Lci(4:6,4,kn)=v_md(:,2,kn)
          Lci(4:6,5,kn)=v_md(:,1,kn)
          Lci(4:6,6,kn)=v_md(:,3,kn)
      end select
    end do
  end subroutine fbem_fem_degshell_Lci

  !! Calculate the coordinate transformation matrix Lc. Transform all nodes with local rotations (5 DOF), to 5 or 6 DOF
  !! nodes: u=Lc·u', dim(u')=5*n_nodes
  subroutine fbem_fem_degshell_Lc(etype,n_dof_element,n_dof_node,v_md,Lc)
    implicit none
    ! I/O
    integer           :: etype                                   !! Type of element (displacements interpolation): tri3, tri6, quad4, quad8, quad9.
    integer           :: n_dof_element                           !! Total number of element DOF
    integer           :: n_dof_node(fbem_n_nodes(etype))         !! Number of DOF (5 (local rotations) or 6 (global rotations)) of each node
    real(kind=real64) :: v_md(3,3,fbem_n_nodes(etype))           !! Local axes for each mid-node for the rotation degrees of freedom.
    real(kind=real64) :: Lc(n_dof_element,5*fbem_n_nodes(etype)) !! Coordinate transformation matrix. Transform all nodes with local rotations (5 DOF), to 5 or 6 DOF nodes: u=Lc·u' (u' is enlarged, i.e. dim(u')=dim(u))
    ! Local
    integer           :: n_nodes                         ! Number of nodes
    integer           :: kn                              ! Counter of nodes
    integer           :: kdofe                           ! Counter of DOF
    integer           :: kis, kie                        ! Global indices
    integer           :: n_dof                           ! Number of DOF
    real(kind=real64) :: Lci(6,5)                        ! Nodal coordinate transformation matrix
    ! Number of mid-plane nodes
    n_nodes=fbem_n_nodes(etype)
    ! Initialize
    Lc=0.d0
    kdofe=0
    ! Calculate
    do kn=1,n_nodes
      n_dof=n_dof_node(kn)
      Lci=0.d0
      select case (n_dof)
        case (5)
          Lci(1,1)=1.d0
          Lci(2,2)=1.d0
          Lci(3,3)=1.d0
          Lci(4,4)=1.d0
          Lci(5,5)=1.d0
        case (6)
          Lci(1,1)=1.d0
          Lci(2,2)=1.d0
          Lci(3,3)=1.d0
          Lci(4:6,4)=v_md(:,2,kn)
          Lci(4:6,5)=v_md(:,1,kn)
      end select
      kis=kdofe+1
      kie=kdofe+n_dof
      Lc(kis:kie,(5*kn-4):(5*kn))=Lci(1:n_dof,1:5)
      kdofe=kdofe+n_dof
    end do
  end subroutine fbem_fem_degshell_Lc

  !! Calculate the coordinate transformation matrix Lc enlarged. Transform all nodes with local rotations (5 DOF), to 5 or 6 DOF
  !! nodes: u=Lc·u' (u' is enlarged, i.e. dim(u')=dim(u))
  subroutine fbem_fem_degshell_Lc_enlarged(etype,n_dof_element,n_dof_node,v_md,Lc)
    implicit none
    ! I/O
    integer           :: etype                           !! Type of element (displacements interpolation): tri3, tri6, quad4, quad8, quad9.
    integer           :: n_dof_element                   !! Total number of element DOF
    integer           :: n_dof_node(fbem_n_nodes(etype)) !! Number of DOF (5 (local rotations) or 6 (global rotations)) of each node
    real(kind=real64) :: v_md(3,3,fbem_n_nodes(etype))   !! Local axes for each mid-node for the rotation degrees of freedom.
    real(kind=real64) :: Lc(n_dof_element,n_dof_element) !! Coordinate transformation matrix. Transform all nodes with local rotations (5 DOF), to 5 or 6 DOF nodes: u=Lc·u' (u' is enlarged, i.e. dim(u')=dim(u))
    ! Local
    integer           :: n_nodes                         ! Number of nodes
    integer           :: kn                              ! Counter of nodes
    integer           :: kdofe                           ! Counter of DOF
    integer           :: kis, kie                        ! Global indices
    integer           :: n_dof                           ! Number of DOF
    real(kind=real64) :: Lci(6,6)                        ! Nodal coordinate transformation matrix
    ! Number of mid-plane nodes
    n_nodes=fbem_n_nodes(etype)
    ! Initialize
    Lc=0.d0
    kdofe=0
    ! Calculate
    do kn=1,n_nodes
      n_dof=n_dof_node(kn)
      Lci=0.d0
      select case (n_dof)
        case (5)
          Lci(1,1)=1.d0
          Lci(2,2)=1.d0
          Lci(3,3)=1.d0
          Lci(4,4)=1.d0
          Lci(5,5)=1.d0
        case (6)
          Lci(1,1)=1.d0
          Lci(2,2)=1.d0
          Lci(3,3)=1.d0
          Lci(4:6,4)=v_md(:,2,kn)
          Lci(4:6,5)=v_md(:,1,kn)
          Lci(4:6,6)=v_md(:,3,kn)
      end select
      kis=kdofe+1
      kie=kdofe+n_dof
      Lc(kis:kie,kis:kie)=Lci(1:n_dof,1:n_dof)
      kdofe=kdofe+n_dof
    end do
  end subroutine fbem_fem_degshell_Lc_enlarged

  !! Calculate the displacements shape functions matrix N at a givel local coordinate (5 DOF for each node)
  subroutine fbem_fem_degshell_N(etype,v_md,t_md,xi,N)
    implicit none
    ! I/O
    integer           :: etype                         !! Type of element (displacements interpolation): tri3, tri6, quad4, quad8, quad9.
    real(kind=real64) :: v_md(3,3,fbem_n_nodes(etype)) !! Local axes for each mid-node for the rotation degrees of freedom.
    real(kind=real64) :: t_md(fbem_n_nodes(etype))     !! Thickness of each mid-node in the v_3 direction.
    real(kind=real64) :: xi(3)                         !! Local coordinate
    real(kind=real64) :: N(3,5*fbem_n_nodes(etype))    !! Shape functions matrix
    ! Local
    integer           :: n_md                           ! Number of mid-nodes
    integer           :: kmd                            ! Counter of mid-nodes
    real(kind=real64) :: aux(10)                        ! Auxiliary variable needed for shape_functions module resources
    real(kind=real64) :: phi(fbem_n_nodes(etype))       ! phi shape functions
    real(kind=real64) :: varphi(fbem_n_nodes(etype))    ! varphi shape functions
    integer           :: ki                             ! Counters and nodal DOF limits
    ! Number of mid-nodes
    n_md=fbem_n_nodes(etype)
    ! Mid-plane shape functions
#   define delta 0.d0
#   include <phi_2d.rc>
#   undef delta
    ! Thickness shape function
    varphi=phi*0.5d0*xi(3)*t_md
    ! Build shape functions matrix
    N=0.d0
    do kmd=1,n_md
      ki=(kmd-1)*5+1
      N(1,ki  )= phi(kmd)
      N(2,ki+1)= phi(kmd)
      N(3,ki+2)= phi(kmd)
      N(:,ki+3)= varphi(kmd)*v_md(:,1,kmd)
      N(:,ki+4)=-varphi(kmd)*v_md(:,2,kmd)
    end do
  end subroutine fbem_fem_degshell_N

  !! Calculate the displacements shape functions matrix N^(i) at a givel local coordinate (5 DOF for each node)
  subroutine fbem_fem_degshell_Ni(etype,v_md,t_md,xi,Ni)
    implicit none
    ! I/O
    integer           :: etype                         !! Type of element (displacements interpolation): tri3, tri6, quad4, quad8, quad9.
    real(kind=real64) :: v_md(3,3,fbem_n_nodes(etype)) !! Local axes for each mid-node for the rotation degrees of freedom.
    real(kind=real64) :: t_md(fbem_n_nodes(etype))     !! Thickness of each mid-node in the v_3 direction.
    real(kind=real64) :: xi(3)                         !! Local coordinate
    real(kind=real64) :: Ni(3,5,fbem_n_nodes(etype))   !! Shape function matrix for each node
    ! Local
    integer           :: n_md                           ! Number of mid-nodes
    integer           :: k                              ! Counter of mid-nodes
    real(kind=real64) :: aux(10)                        ! Auxiliary variable needed for shape_functions module resources
    real(kind=real64) :: phi(fbem_n_nodes(etype))       ! phi shape functions
    real(kind=real64) :: varphi(fbem_n_nodes(etype))    ! varphi shape functions
    ! Number of mid-nodes
    n_md=fbem_n_nodes(etype)
    ! Mid-plane shape functions
#   define delta 0.d0
#   include <phi_2d.rc>
#   undef delta
    ! Thickness shape function
    varphi=phi*0.5d0*xi(3)*t_md
    ! Build shape functions matrix
    Ni=0.d0
    do k=1,n_md
      Ni(1,1,k)= phi(k)
      Ni(2,2,k)= phi(k)
      Ni(3,3,k)= phi(k)
      Ni(:,4,k)= varphi(k)*v_md(:,1,k)
      Ni(:,5,k)=-varphi(k)*v_md(:,2,k)
    end do
  end subroutine fbem_fem_degshell_Ni

  !! Calculate the stiffness matrix K for statics, with real E and K, orthotropic case
  subroutine fbem_fem_degshell_K_ot_real(etype,x_midnodes,v_midnode,t_midnodes,fd1,E11,E22,nu12,nu21,G12,G13,G23,kappa,ngpip,ngpsh,ngpth,K,V)
    implicit none
    ! I/O
    integer           :: etype                                          !! Type of element (displacements interpolation): tri3, tri6, quad4, quad8, quad9.
    real(kind=real64) :: x_midnodes(3,fbem_n_nodes(etype))              !! Position vectors of the mid-plane nodes.
    real(kind=real64) :: v_midnode(3,3,fbem_n_nodes(etype))             !! Local axes for each mid-node for the rotation degrees of freedom.
    real(kind=real64) :: t_midnodes(fbem_n_nodes(etype))                !! Thickness of each mid-node in the v_3 direction.
    real(kind=real64) :: fd1(3)                                         !! Reference global vector for fiber direction 1 (must be normalized)
    real(kind=real64) :: E11, E22                                       !! Young's moduli in fiber directions 1 and 2
    real(kind=real64) :: nu12, nu21                                     !! Poisson's ratios
    real(kind=real64) :: G12, G13, G23                                  !! Shear moduli for the three planes
    real(kind=real64) :: kappa(3)                                       !! Shear correction factors: kx', ky',-
    integer           :: ngpip                                          !! Number of Gauss-Legendre integration points for in-plane coordinates (xi1,xi2) for the membrane-bending (inplane) local strain contribution.
    integer           :: ngpsh                                          !! Number of Gauss-Legendre integration points for in-plane coordinates (xi1,xi2) for the shear local strain contribution.
    integer           :: ngpth                                          !! Number of Gauss-Legendre integration points for thickness coordinate (xi3)
    real(kind=real64) :: K(5*fbem_n_nodes(etype),5*fbem_n_nodes(etype)) !! Stiffness matrix
    real(kind=real64) :: V                                              !! Volume of the element
    ! Local
    integer           :: n_midnodes                           ! Number of mid-nodes
    integer           :: kmidnode                             ! Counter of mid-nodes
    integer           :: contribution                         ! Contribution part
    integer           :: ngp                                  ! Number of Gauss points
    integer           :: rule                                 ! Rule of Wandzura quadrature
    integer           :: kxi1, kxi2, kxi3, kxit               ! Integration points counters
    real(kind=real64) :: xi1, xi2, xi3, xi(2), w1, w2, w3, wt ! Curvilinear coordinates and quadrature weights
    real(kind=real64) :: aux(10)                              ! Auxiliary variable needed for shape_functions module resources
    real(kind=real64) :: phi(fbem_n_nodes(etype))             ! phi shape functions
    real(kind=real64) :: dphidxi1(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_1
    real(kind=real64) :: dphidxi2(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_2
    real(kind=real64) :: dphidxi3(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_3
    real(kind=real64) :: varphi(fbem_n_nodes(etype))          ! varphi shape functions
    real(kind=real64) :: dvarphidxi1(fbem_n_nodes(etype))     ! varphi shape functions derivatives with respect to xi_1
    real(kind=real64) :: dvarphidxi2(fbem_n_nodes(etype))     ! varphi shape functions derivatives with respect to xi_2
    real(kind=real64) :: dvarphidxi3(fbem_n_nodes(etype))     ! varphi shape functions derivatives with respect to xi_3
    !real(kind=real64) :: x(3)                                 ! Position vector of the integration point
    real(kind=real64) :: J(3,3), H(3,3), detJ                 ! Jacobian matrix, its inverse and the jacobian determinant
    real(kind=real64) :: jw                                   ! det(J) * weights
    real(kind=real64) :: T1(3), T2(3), N(3)                   ! Derivatives of position with respect to curvilinear coordinates and the normal vector to the mid-plane
    real(kind=real64) :: ep1(3), ep2(3), ep3(3)               ! Local ortogonal axes
    real(kind=real64) :: E(5,6)                               ! E matrix
    real(kind=real64) :: G(6,9)                               ! G matrix
    real(kind=real64) :: M(9,5)                               ! M matrix (shape function matrices derivatives)
    real(kind=real64) :: Bp(5,5,fbem_n_nodes(etype))          ! B' matrix
    real(kind=real64) :: B(6,5,fbem_n_nodes(etype))           ! B matrix
    real(kind=real64) :: Dp(5,5)                              ! D' constitutive matrix (local coordinates)
    real(kind=real64) :: Dm(5,5)                              ! Dm constitutive matrix (material axes)
    real(kind=real64) :: Tm(5,5)                              ! Material to local coordinates matrix
    real(kind=real64) :: fd1d(3), fd2d(3), modfd              ! Projected material direcctions from fd1
    real(kind=real64) :: theta, ct, st                        ! Angle between fiber direction 1 and local orthogonal axis (x_1'), cos(theta) and sin(theta)
    integer           :: ki, kis, kie, kj, kjs, kje           ! Counters and nodal DOF limits
    !
    ! Initialization
    !
    ! Initialize stiffness matrix
    K=0.d0
    ! Initialize volume
    V=0.d0
    ! Number of mid-nodes
    n_midnodes=fbem_n_nodes(etype)
    ! Local constitutive matrix Dm (in material axes)
    Dm=0.d0
    Dm(1,1)=E11/(1.d0-nu12*nu21)
    Dm(1,2)=E22*nu12/(1.d0-nu12*nu21)
    Dm(2,1)=Dm(1,2)
    Dm(2,2)=E22/(1.d0-nu12*nu21)
    Dm(3,3)=G12
    Dm(4,4)=kappa(1)*G13
    Dm(5,5)=kappa(2)*G23
    !
    ! Switch between triangular and quadrilateral elements
    !
    select case (etype)
      !
      ! Triangular elements
      !
      case (fbem_tri3,fbem_tri6)
        !
        ! Integrate each part (in-plane and shear contributions) using different number of gaussian points
        !
        do contribution=1,2
          !
          ! Select which part must be integrated with what number of gaussian points
          !
          if (ngpip.ne.ngpsh) then
            select case (contribution)
              ! Integrate in-plane contribution with ngpip number of gaussian points
              case (1)
                ngp=ngpip
              ! Integrate shear contribution with ngpsh number of gaussian points
              case (2)
                ngp=ngpsh
            end select
          else
            ! Integrate all together with with ngpip=ngpsh number of gaussian points
            ngp=ngpip
            if (contribution.eq.2) exit
          end if
          !
          ! Loops through integration points
          !
          ! Transform to order for Wandzura rules
          rule=2*ngp-1
          do kxit=1,wantri_n(rule)
            ! xi_1, xi_2 and w_t
            xi1=wantri_xi1(kxit,rule)
            xi2=wantri_xi2(kxit,rule)
            wt=wantri_w(kxit,rule)
            do kxi3=1,ngpth
              ! xi_3 and w_3
              xi3=gl11_xi(kxi3,ngpth)
              w3=gl11_w(kxi3,ngpth)
              ! In-plane shape functions and their first derivatives with respect to xi_1, xi_2 and xi_3 at (xi_1,xi_2,xi_3)
              xi(1)=xi1
              xi(2)=xi2
#             define delta 0.0d0
#             include <phi_and_dphidxik_2d.rc>
#             undef delta
              dphidxi3=0.d0
              ! Thickness shape function and its derivative with respect to xi_1, xi_2 and xi_3 at (xi_1,xi_2,xi_3)
              varphi=phi*0.5d0*xi3*t_midnodes
              dvarphidxi1=dphidxi1*0.5d0*xi3*t_midnodes
              dvarphidxi2=dphidxi2*0.5d0*xi3*t_midnodes
              dvarphidxi3=phi*0.5d0*t_midnodes
              ! Calculate position vector x, and Jacobian matrix at (xi_1,xi_2,xi_3)
              !x=0.d0
              J=0.d0
              do kmidnode=1,n_midnodes
                !x=x+phi(kmidnode)*x_midnodes(:,kmidnode)+varphi(kmidnode)*v_midnode(:,3,kmidnode)
                J(1,:)=J(1,:)+dphidxi1(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi1(kmidnode)*v_midnode(:,3,kmidnode)
                J(2,:)=J(2,:)+dphidxi2(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi2(kmidnode)*v_midnode(:,3,kmidnode)
                J(3,:)=J(3,:)+dphidxi3(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi3(kmidnode)*v_midnode(:,3,kmidnode)
              end do
              ! Calculate inv(J) and det(J)
              call fbem_invert_3x3_matrix(J,H,detJ)
              ! Calculate local orthogonal system of coordinates (ep_1,ep_2,ep_3) at (xi_1,xi_2,xi_3)
              ! Tangents T1 and T2
              T1=J(1,:)
              T2=J(2,:)
              ! Calculate N (normal vector) as T1 x T2 at (xi_1,xi_2,0)
              N(1)=T1(2)*T2(3)-T1(3)*T2(2)
              N(2)=T1(3)*T2(1)-T1(1)*T2(3)
              N(3)=T1(1)*T2(2)-T1(2)*T2(1)
              ! ep_3 = n
              ep3=N/sqrt(dot_product(N,N))
              ! ep_1 = t1
              ep1=T1/sqrt(dot_product(T1,T1))
              ! ep_2 = ep_3 x ep_1
              ep2(1)=ep3(2)*ep1(3)-ep3(3)*ep1(2)
              ep2(2)=ep3(3)*ep1(1)-ep3(1)*ep1(3)
              ep2(3)=ep3(1)*ep1(2)-ep3(2)*ep1(1)
              ! Global (x) to local (x') tensor transformation matrix
              E=0.d0
              E(1,1:3)=ep1**2
              E(1,4)=ep1(1)*ep1(2)
              E(1,5)=ep1(2)*ep1(3)
              E(1,6)=ep1(1)*ep1(3)
              E(2,1:3)=ep2**2
              E(2,4)=ep2(1)*ep2(2)
              E(2,5)=ep2(2)*ep2(3)
              E(2,6)=ep2(1)*ep2(3)
              E(3,1)=ep1(1)*ep2(1)
              E(3,2)=ep1(2)*ep2(2)
              E(3,3)=ep1(3)*ep2(3)
              E(4,1)=ep2(1)*ep3(1)
              E(4,2)=ep2(2)*ep3(2)
              E(4,3)=ep2(3)*ep3(3)
              E(5,1)=ep1(1)*ep3(1)
              E(5,2)=ep1(2)*ep3(2)
              E(5,3)=ep1(3)*ep3(3)
              E(3:5,1:3)=2.d0*E(3:5,1:3)
              E(3,4)=ep1(1)*ep2(2)+ep1(2)*ep2(1)
              E(3,5)=ep1(2)*ep2(3)+ep1(3)*ep2(2)
              E(3,6)=ep1(1)*ep2(3)+ep1(3)*ep2(1)
              E(4,4)=ep2(1)*ep3(2)+ep2(2)*ep3(1)
              E(4,5)=ep2(2)*ep3(3)+ep2(3)*ep3(2)
              E(4,6)=ep2(1)*ep3(3)+ep2(3)*ep3(1)
              E(5,4)=ep1(1)*ep3(2)+ep1(2)*ep3(1)
              E(5,5)=ep1(2)*ep3(3)+ep1(3)*ep3(2)
              E(5,6)=ep1(1)*ep3(3)+ep1(3)*ep3(1)
              if (ngpip.ne.ngpsh) then
                select case (contribution)
                  ! Integrate in-plane contribution => Set zero the shear contribution
                  case (1)
                    E(4:5,:)=0.d0
                  ! Integrate shear contribution => Set zero the in-plane contribution
                  case (2)
                    E(1:3,:)=0.d0
                end select
              end if
              ! Derivative transformation matrix for curvilinear to global cartesian tensor transformation
              G=0.d0
              G(1,1)=H(1,1)
              G(2,2)=H(2,1)
              G(3,3)=H(3,1)
              G(4,1)=H(2,1)
              G(4,2)=H(1,1)
              G(5,2)=H(3,1)
              G(5,3)=H(2,1)
              G(6,1)=H(3,1)
              G(6,3)=H(1,1)
              G(1,4)=H(1,2)
              G(2,5)=H(2,2)
              G(3,6)=H(3,2)
              G(4,4)=H(2,2)
              G(4,5)=H(1,2)
              G(5,5)=H(3,2)
              G(5,6)=H(2,2)
              G(6,4)=H(3,2)
              G(6,6)=H(1,2)
              G(1,7)=H(1,3)
              G(2,8)=H(2,3)
              G(3,9)=H(3,3)
              G(4,7)=H(2,3)
              G(4,8)=H(1,3)
              G(5,8)=H(3,3)
              G(5,9)=H(2,3)
              G(6,7)=H(3,3)
              G(6,9)=H(1,3)
              ! Build matrix B for all nodes
              do kmidnode=1,n_midnodes
                ! Matrix of derivatives of shape functions matrices with respect to xi1, xi2 and xi3
                M=0.d0
                M(  1,1)= dphidxi1(kmidnode)
                M(  2,2)= dphidxi1(kmidnode)
                M(  3,3)= dphidxi1(kmidnode)
                M(1:3,4)= dvarphidxi1(kmidnode)*v_midnode(:,1,kmidnode)
                M(1:3,5)=-dvarphidxi1(kmidnode)*v_midnode(:,2,kmidnode)
                M(  4,1)= dphidxi2(kmidnode)
                M(  5,2)= dphidxi2(kmidnode)
                M(  6,3)= dphidxi2(kmidnode)
                M(4:6,4)= dvarphidxi2(kmidnode)*v_midnode(:,1,kmidnode)
                M(4:6,5)=-dvarphidxi2(kmidnode)*v_midnode(:,2,kmidnode)
                M(  7,1)= dphidxi3(kmidnode)
                M(  8,2)= dphidxi3(kmidnode)
                M(  9,3)= dphidxi3(kmidnode)
                M(7:9,4)= dvarphidxi3(kmidnode)*v_midnode(:,1,kmidnode)
                M(7:9,5)=-dvarphidxi3(kmidnode)*v_midnode(:,2,kmidnode)
                ! B matrix for kmidnode
                B(:,:,kmidnode)=matmul(G,M)
                ! B' matrix for kmidnode
                Bp(:,:,kmidnode)=matmul(E,B(:,:,kmidnode))
              end do
              ! Build D' from Dm and the reference vector of fiber direction 1
              ! fd2d = ep3 x fd1 gives a vector in the plane of ep1 and ep2
              fd2d(1)=ep3(2)*fd1(3)-ep3(3)*fd1(2)
              fd2d(2)=ep3(3)*fd1(1)-ep3(1)*fd1(3)
              fd2d(3)=ep3(1)*fd1(2)-ep3(2)*fd1(1)
              modfd=sqrt(dot_product(fd2d,fd2d))
              ! ep3 and fd1 cannot be parallel (indeterminacy of the fiber direction 1)
              if (modfd.le.1.d-6) then
                call fbem_error_message(error_unit,0,__FILE__,__LINE__,&
                                        'reference vector of fiber direction 1 is almost parallel to ep3')
              end if
              fd2d=fd2d/modfd
              ! fd1d = fd2d x ep3 gives definitive fiber direction 1 on the lamina
              fd1d(1)=fd2d(2)*ep3(3)-fd2d(3)*ep3(2)
              fd1d(2)=fd2d(3)*ep3(1)-fd2d(1)*ep3(3)
              fd1d(3)=fd2d(1)*ep3(2)-fd2d(2)*ep3(1)
              modfd=sqrt(dot_product(fd1d,fd1d))
              fd1d=fd1d/modfd
              ! Angle between definitive fiber direction 1 and local axis 1'
              theta=acos(dot_product(fd1d,ep1))
              ct=cos(theta)
              st=sin(theta)
              Tm=0.d0
              Tm(1,1)=ct**2
              Tm(2,2)=Tm(1,1)
              Tm(1,2)=st**2
              Tm(2,1)=Tm(1,2)
              Tm(3,3)=Tm(1,1)-Tm(1,2)
              Tm(1,3)=st*ct
              Tm(2,3)=-Tm(1,3)
              Tm(3,1)=-2.d0*Tm(1,3)
              Tm(3,2)=2.d0*Tm(1,3)
              Tm(4,4)=ct
              Tm(5,5)=ct
              Tm(4,5)=st
              Tm(5,4)=-st
              ! Dp = Tm^T · Dm · Tm
              Dp=matmul(transpose(Tm),matmul(Dm,Tm))
              ! det(J) * weights
              jw=detJ*wt*w3
              ! Volume
              V=V+jw
              ! Build the element stiffness matrix
              do ki=1,n_midnodes
                kis=(ki-1)*5+1
                kie=kis+4
                do kj=1,n_midnodes
                  kjs=(kj-1)*5+1
                  kje=kjs+4
                  K(kis:kie,kjs:kje)=K(kis:kie,kjs:kje)+matmul(transpose(Bp(:,:,ki)),matmul(Dp,Bp(:,:,kj)))*jw
                end do
              end do
            end do ! xi_3
          end do ! xi_1 and xi_2
        end do ! contributions
      !
      ! Quadrilateral elements
      !
      case (fbem_quad4,fbem_quad8,fbem_quad9)
        !
        ! Integrate each part (in-plane and shear contributions) using different number of gaussian points
        !
        do contribution=1,2
          !
          ! Select which part must be integrated with what number of gaussian points
          !
          if (ngpip.ne.ngpsh) then
            select case (contribution)
              ! Integrate in-plane contribution with ngpip number of gaussian points
              case (1)
                ngp=ngpip
              ! Integrate shear contribution with ngpsh number of gaussian points
              case (2)
                ngp=ngpsh
            end select
          else
            ! Integrate all together with with ngpip=ngpsh number of gaussian points
            ngp=ngpip
            if (contribution.eq.2) exit
          end if
          !
          ! Loops through integration points
          !
          do kxi1=1,ngp
            ! xi_1 and w_1
            xi1=gl11_xi(kxi1,ngp)
            w1=gl11_w(kxi1,ngp)
            do kxi2=1,ngp
              ! xi_2 and w_2
              xi2=gl11_xi(kxi2,ngp)
              w2=gl11_w(kxi2,ngp)
              do kxi3=1,ngpth
                ! xi_3 and w_3
                xi3=gl11_xi(kxi3,ngpth)
                w3=gl11_w(kxi3,ngpth)
                ! In-plane shape functions and their first derivatives with respect to xi_1, xi_2 and xi_3 at (xi_1,xi_2,xi_3)
                xi(1)=xi1
                xi(2)=xi2
#               define delta 0.0d0
#               include <phi_and_dphidxik_2d.rc>
#               undef delta
                dphidxi3=0.d0
                ! Thickness shape function and its derivative with respect to xi_1, xi_2 and xi_3 at (xi_1,xi_2,xi_3)
                varphi=phi*0.5d0*xi3*t_midnodes
                dvarphidxi1=dphidxi1*0.5d0*xi3*t_midnodes
                dvarphidxi2=dphidxi2*0.5d0*xi3*t_midnodes
                dvarphidxi3=phi*0.5d0*t_midnodes
                ! Calculate position vector x, and Jacobian matrix at (xi_1,xi_2,xi_3)
                !x=0.d0
                J=0.d0
                do kmidnode=1,n_midnodes
                  !x=x+phi(kmidnode)*x_midnodes(:,kmidnode)+varphi(kmidnode)*v_midnode(:,3,kmidnode)
                  J(1,:)=J(1,:)+dphidxi1(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi1(kmidnode)*v_midnode(:,3,kmidnode)
                  J(2,:)=J(2,:)+dphidxi2(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi2(kmidnode)*v_midnode(:,3,kmidnode)
                  J(3,:)=J(3,:)+dphidxi3(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi3(kmidnode)*v_midnode(:,3,kmidnode)
                end do
                ! Calculate inv(J) and det(J)
                call fbem_invert_3x3_matrix(J,H,detJ)
                ! Calculate local orthogonal system of coordinates (ep_1,ep_2,ep_3) at (xi_1,xi_2,xi_3)
                ! Tangents T1 and T2
                T1=J(1,:)
                T2=J(2,:)
                ! Calculate N (normal vector) as T1 x T2 at (xi_1,xi_2,0)
                N(1)=T1(2)*T2(3)-T1(3)*T2(2)
                N(2)=T1(3)*T2(1)-T1(1)*T2(3)
                N(3)=T1(1)*T2(2)-T1(2)*T2(1)
                ! ep_3 = n
                ep3=N/sqrt(dot_product(N,N))
                ! ep_1 = t1
                ep1=T1/sqrt(dot_product(T1,T1))
                ! ep_2 = ep_3 x ep_1
                ep2(1)=ep3(2)*ep1(3)-ep3(3)*ep1(2)
                ep2(2)=ep3(3)*ep1(1)-ep3(1)*ep1(3)
                ep2(3)=ep3(1)*ep1(2)-ep3(2)*ep1(1)
                ! Global (x) to local (x') tensor transformation matrix
                E=0.d0
                E(1,1:3)=ep1**2
                E(1,4)=ep1(1)*ep1(2)
                E(1,5)=ep1(2)*ep1(3)
                E(1,6)=ep1(1)*ep1(3)
                E(2,1:3)=ep2**2
                E(2,4)=ep2(1)*ep2(2)
                E(2,5)=ep2(2)*ep2(3)
                E(2,6)=ep2(1)*ep2(3)
                E(3,1)=ep1(1)*ep2(1)
                E(3,2)=ep1(2)*ep2(2)
                E(3,3)=ep1(3)*ep2(3)
                E(4,1)=ep2(1)*ep3(1)
                E(4,2)=ep2(2)*ep3(2)
                E(4,3)=ep2(3)*ep3(3)
                E(5,1)=ep1(1)*ep3(1)
                E(5,2)=ep1(2)*ep3(2)
                E(5,3)=ep1(3)*ep3(3)
                E(3:5,1:3)=2.d0*E(3:5,1:3)
                E(3,4)=ep1(1)*ep2(2)+ep1(2)*ep2(1)
                E(3,5)=ep1(2)*ep2(3)+ep1(3)*ep2(2)
                E(3,6)=ep1(1)*ep2(3)+ep1(3)*ep2(1)
                E(4,4)=ep2(1)*ep3(2)+ep2(2)*ep3(1)
                E(4,5)=ep2(2)*ep3(3)+ep2(3)*ep3(2)
                E(4,6)=ep2(1)*ep3(3)+ep2(3)*ep3(1)
                E(5,4)=ep1(1)*ep3(2)+ep1(2)*ep3(1)
                E(5,5)=ep1(2)*ep3(3)+ep1(3)*ep3(2)
                E(5,6)=ep1(1)*ep3(3)+ep1(3)*ep3(1)
                if (ngpip.ne.ngpsh) then
                  select case (contribution)
                    ! Integrate in-plane contribution => Set zero the shear contribution
                    case (1)
                      E(4:5,:)=0.d0
                    ! Integrate shear contribution => Set zero the in-plane contribution
                    case (2)
                      E(1:3,:)=0.d0
                  end select
                end if
                ! Derivative transformation matrix for curvilinear to global cartesian tensor transformation
                G=0.d0
                G(1,1)=H(1,1)
                G(2,2)=H(2,1)
                G(3,3)=H(3,1)
                G(4,1)=H(2,1)
                G(4,2)=H(1,1)
                G(5,2)=H(3,1)
                G(5,3)=H(2,1)
                G(6,1)=H(3,1)
                G(6,3)=H(1,1)
                G(1,4)=H(1,2)
                G(2,5)=H(2,2)
                G(3,6)=H(3,2)
                G(4,4)=H(2,2)
                G(4,5)=H(1,2)
                G(5,5)=H(3,2)
                G(5,6)=H(2,2)
                G(6,4)=H(3,2)
                G(6,6)=H(1,2)
                G(1,7)=H(1,3)
                G(2,8)=H(2,3)
                G(3,9)=H(3,3)
                G(4,7)=H(2,3)
                G(4,8)=H(1,3)
                G(5,8)=H(3,3)
                G(5,9)=H(2,3)
                G(6,7)=H(3,3)
                G(6,9)=H(1,3)
                ! Build matrix B for all nodes
                do kmidnode=1,n_midnodes
                  ! Matrix of derivatives of shape functions matrices with respect to xi1, xi2 and xi3
                  M=0.d0
                  M(  1,1)= dphidxi1(kmidnode)
                  M(  2,2)= dphidxi1(kmidnode)
                  M(  3,3)= dphidxi1(kmidnode)
                  M(1:3,4)= dvarphidxi1(kmidnode)*v_midnode(:,1,kmidnode)
                  M(1:3,5)=-dvarphidxi1(kmidnode)*v_midnode(:,2,kmidnode)
                  M(  4,1)= dphidxi2(kmidnode)
                  M(  5,2)= dphidxi2(kmidnode)
                  M(  6,3)= dphidxi2(kmidnode)
                  M(4:6,4)= dvarphidxi2(kmidnode)*v_midnode(:,1,kmidnode)
                  M(4:6,5)=-dvarphidxi2(kmidnode)*v_midnode(:,2,kmidnode)
                  M(  7,1)= dphidxi3(kmidnode)
                  M(  8,2)= dphidxi3(kmidnode)
                  M(  9,3)= dphidxi3(kmidnode)
                  M(7:9,4)= dvarphidxi3(kmidnode)*v_midnode(:,1,kmidnode)
                  M(7:9,5)=-dvarphidxi3(kmidnode)*v_midnode(:,2,kmidnode)
                  ! B matrix for kmidnode
                  B(:,:,kmidnode)=matmul(G,M)
                  ! B' matrix for kmidnode
                  Bp(:,:,kmidnode)=matmul(E,B(:,:,kmidnode))
                end do
                ! Build D' from Dm and the reference vector of fiber direction 1
                ! fd2d = ep3 x fd1 gives a vector in the plane of ep1 and ep2
                fd2d(1)=ep3(2)*fd1(3)-ep3(3)*fd1(2)
                fd2d(2)=ep3(3)*fd1(1)-ep3(1)*fd1(3)
                fd2d(3)=ep3(1)*fd1(2)-ep3(2)*fd1(1)
                modfd=sqrt(dot_product(fd2d,fd2d))
                ! ep3 and fd1 cannot be parallel (indeterminacy of the fiber direction 1)
                if (modfd.le.1.d-6) then
                  call fbem_error_message(error_unit,0,__FILE__,__LINE__,&
                                          'reference vector of fiber direction 1 is almost parallel to ep3')
                end if
                fd2d=fd2d/modfd
                ! fd1d = fd2d x ep3 gives definitive fiber direction 1 on the lamina
                fd1d(1)=fd2d(2)*ep3(3)-fd2d(3)*ep3(2)
                fd1d(2)=fd2d(3)*ep3(1)-fd2d(1)*ep3(3)
                fd1d(3)=fd2d(1)*ep3(2)-fd2d(2)*ep3(1)
                modfd=sqrt(dot_product(fd1d,fd1d))
                fd1d=fd1d/modfd
                ! Angle between definitive fiber direction 1 and local axis 1'
                theta=acos(dot_product(fd1d,ep1))
                ct=cos(theta)
                st=sin(theta)
                Tm=0.d0
                Tm(1,1)=ct**2
                Tm(2,2)=Tm(1,1)
                Tm(1,2)=st**2
                Tm(2,1)=Tm(1,2)
                Tm(3,3)=Tm(1,1)-Tm(1,2)
                Tm(1,3)=st*ct
                Tm(2,3)=-Tm(1,3)
                Tm(3,1)=-2.d0*Tm(1,3)
                Tm(3,2)=2.d0*Tm(1,3)
                Tm(4,4)=ct
                Tm(5,5)=ct
                Tm(4,5)=st
                Tm(5,4)=-st
                ! Dp = Tm^T · Dm · Tm
                Dp=matmul(transpose(Tm),matmul(Dm,Tm))
                ! det(J) * weights
                jw=detJ*w1*w2*w3
                ! Volume
                V=V+jw
                ! Build the element stiffness matrix
                do ki=1,n_midnodes
                  kis=(ki-1)*5+1
                  kie=kis+4
                  do kj=1,n_midnodes
                    kjs=(kj-1)*5+1
                    kje=kjs+4
                    K(kis:kie,kjs:kje)=K(kis:kie,kjs:kje)+matmul(transpose(Bp(:,:,ki)),matmul(Dp,Bp(:,:,kj)))*jw
                  end do
                end do
              end do ! xi_3
            end do ! xi_2
          end do ! xi_1
        end do ! contributions
      case default
        call fbem_error_message(error_unit,0,__FILE__,__LINE__,'etype={tri3,tri6,quad4,quad8,quad9}')
    end select
  end subroutine fbem_fem_degshell_K_ot_real

  !! Calculate the stiffness matrix K for statics, with real E and K
  subroutine fbem_fem_degshell_K_real(etype,x_midnodes,v_midnode,t_midnodes,Em,nu,kappa,ngpip,ngpsh,ngpth,K,V)
    implicit none
    ! I/O
    integer           :: etype                                          !! Type of element (displacements interpolation): tri3, tri6, quad4, quad8, quad9.
    real(kind=real64) :: x_midnodes(3,fbem_n_nodes(etype))              !! Position vectors of the mid-plane nodes.
    real(kind=real64) :: v_midnode(3,3,fbem_n_nodes(etype))             !! Local axes for each mid-node for the rotation degrees of freedom.
    real(kind=real64) :: t_midnodes(fbem_n_nodes(etype))                !! Thickness of each mid-node in the v_3 direction.
    real(kind=real64) :: Em                                             !! Young's modulus
    real(kind=real64) :: nu                                             !! Poisson's ratio
    real(kind=real64) :: kappa(3)                                       !! Shear correction factors: kx', ky',-
    integer           :: ngpip                                          !! Number of Gauss-Legendre integration points for in-plane coordinates (xi1,xi2) for the membrane-bending (inplane) local strain contribution.
    integer           :: ngpsh                                          !! Number of Gauss-Legendre integration points for in-plane coordinates (xi1,xi2) for the shear local strain contribution.
    integer           :: ngpth                                          !! Number of Gauss-Legendre integration points for thickness coordinate (xi3)
    real(kind=real64) :: K(5*fbem_n_nodes(etype),5*fbem_n_nodes(etype)) !! Stiffness matrix
    real(kind=real64) :: V                                              !! Volume of the element
    ! Local
    integer           :: n_midnodes                           ! Number of mid-nodes
    integer           :: kmidnode                             ! Counter of mid-nodes
    integer           :: contribution                         ! Contribution part
    integer           :: ngp                                  ! Number of Gauss points
    integer           :: rule                                 ! Rule of Wandzura quadrature
    integer           :: kxi1, kxi2, kxi3, kxit               ! Integration points counters
    real(kind=real64) :: xi1, xi2, xi3, xi(2), w1, w2, w3, wt ! Curvilinear coordinates and quadrature weights
    real(kind=real64) :: aux(10)                              ! Auxiliary variable needed for shape_functions module resources
    real(kind=real64) :: phi(fbem_n_nodes(etype))             ! phi shape functions
    real(kind=real64) :: dphidxi1(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_1
    real(kind=real64) :: dphidxi2(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_2
    real(kind=real64) :: dphidxi3(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_3
    real(kind=real64) :: varphi(fbem_n_nodes(etype))          ! varphi shape functions
    real(kind=real64) :: dvarphidxi1(fbem_n_nodes(etype))     ! varphi shape functions derivatives with respect to xi_1
    real(kind=real64) :: dvarphidxi2(fbem_n_nodes(etype))     ! varphi shape functions derivatives with respect to xi_2
    real(kind=real64) :: dvarphidxi3(fbem_n_nodes(etype))     ! varphi shape functions derivatives with respect to xi_3
    !real(kind=real64) :: x(3)                                 ! Position vector of the integration point
    real(kind=real64) :: J(3,3), H(3,3), detJ                 ! Jacobian matrix, its inverse and the jacobian determinant
    real(kind=real64) :: jw                                   ! det(J) * weights
    real(kind=real64) :: T1(3), T2(3), N(3)                   ! Derivatives of position with respect to curvilinear coordinates and the normal vector to the mid-plane
    real(kind=real64) :: ep1(3), ep2(3), ep3(3)               ! Local ortogonal axes
    real(kind=real64) :: E(5,6)                               ! E matrix
    real(kind=real64) :: G(6,9)                               ! G matrix
    real(kind=real64) :: M(9,5)                               ! M matrix (shape function matrices derivatives)
    real(kind=real64) :: Bp(5,5,fbem_n_nodes(etype))          ! B' matrix
    real(kind=real64) :: B(6,5,fbem_n_nodes(etype))           ! B matrix
    real(kind=real64) :: Dp(5,5)                              ! D' constitutive matrix (local coordinates)
    !real(kind=real64) :: D(6,6)                               ! D constitutive matrix (global coordinates)
    integer           :: ki, kis, kie, kj, kjs, kje           ! Counters and nodal DOF limits
    !
    ! Initialization
    !
    ! Initialize stiffness matrix
    K=0.d0
    ! Initialize volume
    V=0.d0
    ! Number of mid-nodes
    n_midnodes=fbem_n_nodes(etype)
    ! Local constitutive matrix D'
    Dp=0.d0
    Dp(1,1)=1.d0
    Dp(1,2)=nu
    Dp(2,1)=nu
    Dp(2,2)=1.d0
    Dp(3,3)=0.5d0*(1.d0-nu)
    Dp(4,4)=kappa(1)*0.5d0*(1.d0-nu)
    Dp(5,5)=kappa(2)*0.5d0*(1.d0-nu)
    Dp=Em/(1.d0-nu**2)*Dp
    !
    ! Switch between triangular and quadrilateral elements
    !
    select case (etype)
      !
      ! Triangular elements
      !
      case (fbem_tri3,fbem_tri6)
        !
        ! Integrate each part (in-plane and shear contributions) using different number of gaussian points
        !
        do contribution=1,2
          !
          ! Select which part must be integrated with what number of gaussian points
          !
          if (ngpip.ne.ngpsh) then
            select case (contribution)
              ! Integrate in-plane contribution with ngpip number of gaussian points
              case (1)
                ngp=ngpip
              ! Integrate shear contribution with ngpsh number of gaussian points
              case (2)
                ngp=ngpsh
            end select
          else
            ! Integrate all together with with ngpip=ngpsh number of gaussian points
            ngp=ngpip
            if (contribution.eq.2) exit
          end if
          !
          ! Loops through integration points
          !
          ! Transform to order for Wandzura rules
          rule=2*ngp-1
          do kxit=1,wantri_n(rule)
            ! xi_1, xi_2 and w_t
            xi1=wantri_xi1(kxit,rule)
            xi2=wantri_xi2(kxit,rule)
            wt=wantri_w(kxit,rule)
            do kxi3=1,ngpth
              ! xi_3 and w_3
              xi3=gl11_xi(kxi3,ngpth)
              w3=gl11_w(kxi3,ngpth)
              ! In-plane shape functions and their first derivatives with respect to xi_1, xi_2 and xi_3 at (xi_1,xi_2,xi_3)
              xi(1)=xi1
              xi(2)=xi2
#             define delta 0.0d0
#             include <phi_and_dphidxik_2d.rc>
#             undef delta
              dphidxi3=0.d0
              ! Thickness shape function and its derivative with respect to xi_1, xi_2 and xi_3 at (xi_1,xi_2,xi_3)
              varphi=phi*0.5d0*xi3*t_midnodes
              dvarphidxi1=dphidxi1*0.5d0*xi3*t_midnodes
              dvarphidxi2=dphidxi2*0.5d0*xi3*t_midnodes
              dvarphidxi3=phi*0.5d0*t_midnodes
              ! Calculate position vector x, and Jacobian matrix at (xi_1,xi_2,xi_3)
              !x=0.d0
              J=0.d0
              do kmidnode=1,n_midnodes
                !x=x+phi(kmidnode)*x_midnodes(:,kmidnode)+varphi(kmidnode)*v_midnode(:,3,kmidnode)
                J(1,:)=J(1,:)+dphidxi1(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi1(kmidnode)*v_midnode(:,3,kmidnode)
                J(2,:)=J(2,:)+dphidxi2(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi2(kmidnode)*v_midnode(:,3,kmidnode)
                J(3,:)=J(3,:)+dphidxi3(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi3(kmidnode)*v_midnode(:,3,kmidnode)
              end do
              ! Calculate inv(J) and det(J)
              call fbem_invert_3x3_matrix(J,H,detJ)
              ! Calculate local orthogonal system of coordinates (ep_1,ep_2,ep_3) at (xi_1,xi_2,xi_3)
              ! Tangents T1 and T2
              T1=J(1,:)
              T2=J(2,:)
              ! Calculate N (normal vector) as T1 x T2 at (xi_1,xi_2,0)
              N(1)=T1(2)*T2(3)-T1(3)*T2(2)
              N(2)=T1(3)*T2(1)-T1(1)*T2(3)
              N(3)=T1(1)*T2(2)-T1(2)*T2(1)
              ! ep_3 = n
              ep3=N/sqrt(dot_product(N,N))
              ! ep_1 = t1
              ep1=T1/sqrt(dot_product(T1,T1))
              ! ep_2 = ep_3 x ep_1
              ep2(1)=ep3(2)*ep1(3)-ep3(3)*ep1(2)
              ep2(2)=ep3(3)*ep1(1)-ep3(1)*ep1(3)
              ep2(3)=ep3(1)*ep1(2)-ep3(2)*ep1(1)
              ! Global (x) to local (x') tensor transformation matrix
              E=0.d0
              E(1,1:3)=ep1**2
              E(1,4)=ep1(1)*ep1(2)
              E(1,5)=ep1(2)*ep1(3)
              E(1,6)=ep1(1)*ep1(3)
              E(2,1:3)=ep2**2
              E(2,4)=ep2(1)*ep2(2)
              E(2,5)=ep2(2)*ep2(3)
              E(2,6)=ep2(1)*ep2(3)
              E(3,1)=ep1(1)*ep2(1)
              E(3,2)=ep1(2)*ep2(2)
              E(3,3)=ep1(3)*ep2(3)
              E(4,1)=ep2(1)*ep3(1)
              E(4,2)=ep2(2)*ep3(2)
              E(4,3)=ep2(3)*ep3(3)
              E(5,1)=ep1(1)*ep3(1)
              E(5,2)=ep1(2)*ep3(2)
              E(5,3)=ep1(3)*ep3(3)
              E(3:5,1:3)=2.d0*E(3:5,1:3)
              E(3,4)=ep1(1)*ep2(2)+ep1(2)*ep2(1)
              E(3,5)=ep1(2)*ep2(3)+ep1(3)*ep2(2)
              E(3,6)=ep1(1)*ep2(3)+ep1(3)*ep2(1)
              E(4,4)=ep2(1)*ep3(2)+ep2(2)*ep3(1)
              E(4,5)=ep2(2)*ep3(3)+ep2(3)*ep3(2)
              E(4,6)=ep2(1)*ep3(3)+ep2(3)*ep3(1)
              E(5,4)=ep1(1)*ep3(2)+ep1(2)*ep3(1)
              E(5,5)=ep1(2)*ep3(3)+ep1(3)*ep3(2)
              E(5,6)=ep1(1)*ep3(3)+ep1(3)*ep3(1)
              if (ngpip.ne.ngpsh) then
                select case (contribution)
                  ! Integrate in-plane contribution => Set zero the shear contribution
                  case (1)
                    E(4:5,:)=0.d0
                  ! Integrate shear contribution => Set zero the in-plane contribution
                  case (2)
                    E(1:3,:)=0.d0
                end select
              end if
              ! Derivative transformation matrix for curvilinear to global cartesian tensor transformation
              G=0.d0
              G(1,1)=H(1,1)
              G(2,2)=H(2,1)
              G(3,3)=H(3,1)
              G(4,1)=H(2,1)
              G(4,2)=H(1,1)
              G(5,2)=H(3,1)
              G(5,3)=H(2,1)
              G(6,1)=H(3,1)
              G(6,3)=H(1,1)
              G(1,4)=H(1,2)
              G(2,5)=H(2,2)
              G(3,6)=H(3,2)
              G(4,4)=H(2,2)
              G(4,5)=H(1,2)
              G(5,5)=H(3,2)
              G(5,6)=H(2,2)
              G(6,4)=H(3,2)
              G(6,6)=H(1,2)
              G(1,7)=H(1,3)
              G(2,8)=H(2,3)
              G(3,9)=H(3,3)
              G(4,7)=H(2,3)
              G(4,8)=H(1,3)
              G(5,8)=H(3,3)
              G(5,9)=H(2,3)
              G(6,7)=H(3,3)
              G(6,9)=H(1,3)
              ! Build matrix B for all nodes
              do kmidnode=1,n_midnodes
                ! Matrix of derivatives of shape functions matrices with respect to xi1, xi2 and xi3
                M=0.d0
                M(  1,1)= dphidxi1(kmidnode)
                M(  2,2)= dphidxi1(kmidnode)
                M(  3,3)= dphidxi1(kmidnode)
                M(1:3,4)= dvarphidxi1(kmidnode)*v_midnode(:,1,kmidnode)
                M(1:3,5)=-dvarphidxi1(kmidnode)*v_midnode(:,2,kmidnode)
                M(  4,1)= dphidxi2(kmidnode)
                M(  5,2)= dphidxi2(kmidnode)
                M(  6,3)= dphidxi2(kmidnode)
                M(4:6,4)= dvarphidxi2(kmidnode)*v_midnode(:,1,kmidnode)
                M(4:6,5)=-dvarphidxi2(kmidnode)*v_midnode(:,2,kmidnode)
                M(  7,1)= dphidxi3(kmidnode)
                M(  8,2)= dphidxi3(kmidnode)
                M(  9,3)= dphidxi3(kmidnode)
                M(7:9,4)= dvarphidxi3(kmidnode)*v_midnode(:,1,kmidnode)
                M(7:9,5)=-dvarphidxi3(kmidnode)*v_midnode(:,2,kmidnode)
                ! B matrix for kmidnode
                B(:,:,kmidnode)=matmul(G,M)
                ! B' matrix for kmidnode
                Bp(:,:,kmidnode)=matmul(E,B(:,:,kmidnode))
                ! Build B matrix again from B', which has only the required contributions (only if integrate with global matrices)
                !B(:,:,kmidnode)=matmul(transpose(E),Bp(:,:,kmidnode))
              end do
              ! det(J) * weights
              jw=detJ*wt*w3
              ! Volume
              V=V+jw
              ! Constitutive matrix D (global coordinates), needed only if integration is performed using global matrices.
              !D=matmul(transpose(E),matmul(Dp,E))
              ! Build the element stiffness matrix
              do ki=1,n_midnodes
                kis=(ki-1)*5+1
                kie=kis+4
                do kj=1,n_midnodes
                  kjs=(kj-1)*5+1
                  kje=kjs+4
                  ! Integration using local matrices (much less expensive)
                  K(kis:kie,kjs:kje)=K(kis:kie,kjs:kje)+matmul(transpose(Bp(:,:,ki)),matmul(Dp,Bp(:,:,kj)))*jw
                  ! Integration using global matrices (computationally expensive)
                  !K(kis:kie,kjs:kje)=K(kis:kie,kjs:kje)+matmul(transpose(B(:,:,ki)),matmul(D,B(:,:,kj)))*jw
                end do
              end do
            end do ! xi_3
          end do ! xi_1 and xi_2
        end do ! contributions
      !
      ! Quadrilateral elements
      !
      case (fbem_quad4,fbem_quad8,fbem_quad9)
        !
        ! Integrate each part (in-plane and shear contributions) using different number of gaussian points
        !
        do contribution=1,2
          !
          ! Select which part must be integrated with what number of gaussian points
          !
          if (ngpip.ne.ngpsh) then
            select case (contribution)
              ! Integrate in-plane contribution with ngpip number of gaussian points
              case (1)
                ngp=ngpip
              ! Integrate shear contribution with ngpsh number of gaussian points
              case (2)
                ngp=ngpsh
            end select
          else
            ! Integrate all together with with ngpip=ngpsh number of gaussian points
            ngp=ngpip
            if (contribution.eq.2) exit
          end if
          !
          ! Loops through integration points
          !
          do kxi1=1,ngp
            ! xi_1 and w_1
            xi1=gl11_xi(kxi1,ngp)
            w1=gl11_w(kxi1,ngp)
            do kxi2=1,ngp
              ! xi_2 and w_2
              xi2=gl11_xi(kxi2,ngp)
              w2=gl11_w(kxi2,ngp)
              do kxi3=1,ngpth
                ! xi_3 and w_3
                xi3=gl11_xi(kxi3,ngpth)
                w3=gl11_w(kxi3,ngpth)
                ! In-plane shape functions and their first derivatives with respect to xi_1, xi_2 and xi_3 at (xi_1,xi_2,xi_3)
                xi(1)=xi1
                xi(2)=xi2
#               define delta 0.0d0
#               include <phi_and_dphidxik_2d.rc>
#               undef delta
                dphidxi3=0.d0
                ! Thickness shape function and its derivative with respect to xi_1, xi_2 and xi_3 at (xi_1,xi_2,xi_3)
                varphi=phi*0.5d0*xi3*t_midnodes
                dvarphidxi1=dphidxi1*0.5d0*xi3*t_midnodes
                dvarphidxi2=dphidxi2*0.5d0*xi3*t_midnodes
                dvarphidxi3=phi*0.5d0*t_midnodes
                ! Calculate position vector x, and Jacobian matrix at (xi_1,xi_2,xi_3)
                !x=0.d0
                J=0.d0
                do kmidnode=1,n_midnodes
                  !x=x+phi(kmidnode)*x_midnodes(:,kmidnode)+varphi(kmidnode)*v_midnode(:,3,kmidnode)
                  J(1,:)=J(1,:)+dphidxi1(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi1(kmidnode)*v_midnode(:,3,kmidnode)
                  J(2,:)=J(2,:)+dphidxi2(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi2(kmidnode)*v_midnode(:,3,kmidnode)
                  J(3,:)=J(3,:)+dphidxi3(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi3(kmidnode)*v_midnode(:,3,kmidnode)
                end do
                ! Calculate inv(J) and det(J)
                call fbem_invert_3x3_matrix(J,H,detJ)
                ! Calculate local orthogonal system of coordinates (ep_1,ep_2,ep_3) at (xi_1,xi_2,xi_3)
                ! Tangents T1 and T2
                T1=J(1,:)
                T2=J(2,:)
                ! Calculate N (normal vector) as T1 x T2 at (xi_1,xi_2,0)
                N(1)=T1(2)*T2(3)-T1(3)*T2(2)
                N(2)=T1(3)*T2(1)-T1(1)*T2(3)
                N(3)=T1(1)*T2(2)-T1(2)*T2(1)
                ! ep_3 = n
                ep3=N/sqrt(dot_product(N,N))
                ! ep_1 = t1
                ep1=T1/sqrt(dot_product(T1,T1))
                ! ep_2 = ep_3 x ep_1
                ep2(1)=ep3(2)*ep1(3)-ep3(3)*ep1(2)
                ep2(2)=ep3(3)*ep1(1)-ep3(1)*ep1(3)
                ep2(3)=ep3(1)*ep1(2)-ep3(2)*ep1(1)
                ! Global (x) to local (x') tensor transformation matrix
                E=0.d0
                E(1,1:3)=ep1**2
                E(1,4)=ep1(1)*ep1(2)
                E(1,5)=ep1(2)*ep1(3)
                E(1,6)=ep1(1)*ep1(3)
                E(2,1:3)=ep2**2
                E(2,4)=ep2(1)*ep2(2)
                E(2,5)=ep2(2)*ep2(3)
                E(2,6)=ep2(1)*ep2(3)
                E(3,1)=ep1(1)*ep2(1)
                E(3,2)=ep1(2)*ep2(2)
                E(3,3)=ep1(3)*ep2(3)
                E(4,1)=ep2(1)*ep3(1)
                E(4,2)=ep2(2)*ep3(2)
                E(4,3)=ep2(3)*ep3(3)
                E(5,1)=ep1(1)*ep3(1)
                E(5,2)=ep1(2)*ep3(2)
                E(5,3)=ep1(3)*ep3(3)
                E(3:5,1:3)=2.d0*E(3:5,1:3)
                E(3,4)=ep1(1)*ep2(2)+ep1(2)*ep2(1)
                E(3,5)=ep1(2)*ep2(3)+ep1(3)*ep2(2)
                E(3,6)=ep1(1)*ep2(3)+ep1(3)*ep2(1)
                E(4,4)=ep2(1)*ep3(2)+ep2(2)*ep3(1)
                E(4,5)=ep2(2)*ep3(3)+ep2(3)*ep3(2)
                E(4,6)=ep2(1)*ep3(3)+ep2(3)*ep3(1)
                E(5,4)=ep1(1)*ep3(2)+ep1(2)*ep3(1)
                E(5,5)=ep1(2)*ep3(3)+ep1(3)*ep3(2)
                E(5,6)=ep1(1)*ep3(3)+ep1(3)*ep3(1)
                if (ngpip.ne.ngpsh) then
                  select case (contribution)
                    ! Integrate in-plane contribution => Set zero the shear contribution
                    case (1)
                      E(4:5,:)=0.d0
                    ! Integrate shear contribution => Set zero the in-plane contribution
                    case (2)
                      E(1:3,:)=0.d0
                  end select
                end if
                ! Derivative transformation matrix for curvilinear to global cartesian tensor transformation
                G=0.d0
                G(1,1)=H(1,1)
                G(2,2)=H(2,1)
                G(3,3)=H(3,1)
                G(4,1)=H(2,1)
                G(4,2)=H(1,1)
                G(5,2)=H(3,1)
                G(5,3)=H(2,1)
                G(6,1)=H(3,1)
                G(6,3)=H(1,1)
                G(1,4)=H(1,2)
                G(2,5)=H(2,2)
                G(3,6)=H(3,2)
                G(4,4)=H(2,2)
                G(4,5)=H(1,2)
                G(5,5)=H(3,2)
                G(5,6)=H(2,2)
                G(6,4)=H(3,2)
                G(6,6)=H(1,2)
                G(1,7)=H(1,3)
                G(2,8)=H(2,3)
                G(3,9)=H(3,3)
                G(4,7)=H(2,3)
                G(4,8)=H(1,3)
                G(5,8)=H(3,3)
                G(5,9)=H(2,3)
                G(6,7)=H(3,3)
                G(6,9)=H(1,3)
                ! Build matrix B for all nodes
                do kmidnode=1,n_midnodes
                  ! Matrix of derivatives of shape functions matrices with respect to xi1, xi2 and xi3
                  M=0.d0
                  M(  1,1)= dphidxi1(kmidnode)
                  M(  2,2)= dphidxi1(kmidnode)
                  M(  3,3)= dphidxi1(kmidnode)
                  M(1:3,4)= dvarphidxi1(kmidnode)*v_midnode(:,1,kmidnode)
                  M(1:3,5)=-dvarphidxi1(kmidnode)*v_midnode(:,2,kmidnode)
                  M(  4,1)= dphidxi2(kmidnode)
                  M(  5,2)= dphidxi2(kmidnode)
                  M(  6,3)= dphidxi2(kmidnode)
                  M(4:6,4)= dvarphidxi2(kmidnode)*v_midnode(:,1,kmidnode)
                  M(4:6,5)=-dvarphidxi2(kmidnode)*v_midnode(:,2,kmidnode)
                  M(  7,1)= dphidxi3(kmidnode)
                  M(  8,2)= dphidxi3(kmidnode)
                  M(  9,3)= dphidxi3(kmidnode)
                  M(7:9,4)= dvarphidxi3(kmidnode)*v_midnode(:,1,kmidnode)
                  M(7:9,5)=-dvarphidxi3(kmidnode)*v_midnode(:,2,kmidnode)
                  ! B matrix for kmidnode
                  B(:,:,kmidnode)=matmul(G,M)
                  ! B' matrix for kmidnode
                  Bp(:,:,kmidnode)=matmul(E,B(:,:,kmidnode))
                  ! Build B matrix again from B', which has only the required contributions (only if integrate with global matrices)
                  !B(:,:,kmidnode)=matmul(transpose(E),Bp(:,:,kmidnode))
                end do
                ! det(J) * weights
                jw=detJ*w1*w2*w3
                ! Volume
                V=V+jw
                ! Constitutive matrix D (global coordinates), needed only if integration is performed using global matrices.
                !D=matmul(transpose(E),matmul(Dp,E))
                ! Build the element stiffness matrix
                do ki=1,n_midnodes
                  kis=(ki-1)*5+1
                  kie=kis+4
                  do kj=1,n_midnodes
                    kjs=(kj-1)*5+1
                    kje=kjs+4
                    ! Integration using local matrices (much less expensive)
                    K(kis:kie,kjs:kje)=K(kis:kie,kjs:kje)+matmul(transpose(Bp(:,:,ki)),matmul(Dp,Bp(:,:,kj)))*jw
                    ! Integration using global matrices (computationally expensive)
                    !K(kis:kie,kjs:kje)=K(kis:kie,kjs:kje)+matmul(transpose(B(:,:,ki)),matmul(D,B(:,:,kj)))*jw
                  end do
                end do
              end do ! xi_3
            end do ! xi_2
          end do ! xi_1
        end do ! contributions
      case default
        call fbem_error_message(error_unit,0,__FILE__,__LINE__,'etype={tri3,tri6,quad4,quad8,quad9}')
    end select
  end subroutine fbem_fem_degshell_K_real

  ! ================================================================================================================================
  ! MITC ELEMENTS
  ! ================================================================================================================================

  subroutine mitc_interpolation_scheme_tp(t,p,n,xi)
    implicit none
    integer           :: t       !! Type of interpolation
    real(kind=real64) :: p(2)    !! Parameters for the interpolation
    integer           :: n       !! Number of tying points
    real(kind=real64) :: xi(2,6) !! Local coordinates of each interpolation point
    select case (t)
      case (1)
        n=1
        xi(:,1)=[ p(1), p(2)]
      case (2)
        n=2
        xi(:,1)=[-p(1), p(2)]
        xi(:,2)=[ p(1), p(2)]
      case (3)
        n=2
        xi(:,1)=[ p(1),-p(2)]
        xi(:,2)=[ p(1), p(2)]
      case (4)
        n=4
        xi(:,1)=[-p(1),-p(2)]
        xi(:,2)=[ p(1),-p(2)]
        xi(:,3)=[-p(1), p(2)]
        xi(:,4)=[ p(1), p(2)]
      case (5)
        n=5
        xi(:,1)=[-p(1),-p(2)]
        xi(:,2)=[ p(1),-p(2)]
        xi(:,3)=[-p(1), p(2)]
        xi(:,4)=[ p(1), p(2)]
        xi(:,5)=[ 0.d0, 0.d0]
      case (6)
        n=6
        xi(:,1)=[-p(1),-p(2)]
        xi(:,2)=[ p(1),-p(2)]
        xi(:,3)=[ 0.d0,-p(2)]
        xi(:,4)=[-p(1), p(2)]
        xi(:,5)=[ p(1), p(2)]
        xi(:,6)=[ 0.d0, p(2)]
      case (7)
        n=6
        xi(:,1)=[-p(1),-p(2)]
        xi(:,2)=[ p(1),-p(2)]
        xi(:,3)=[-p(1), p(2)]
        xi(:,4)=[ p(1), p(2)]
        xi(:,5)=[-p(1), 0.d0]
        xi(:,6)=[ p(1), 0.d0]
      case default
        stop 'ERROR: mitc_interpolation_schemes does not recognize this interpolation'
    end select
  end subroutine mitc_interpolation_scheme_tp

  function mitc_interpolation_scheme_phi(t,p,xi)
    implicit none
    real(kind=real64) :: mitc_interpolation_scheme_phi(6)
    integer           :: t
    real(kind=real64) :: p(2)
    real(kind=real64) :: xi(2)
    real(kind=real64) :: xip(2)
    real(kind=real64) :: aux(5)
    mitc_interpolation_scheme_phi=0.d0
    select case (t)
      case (1)
        mitc_interpolation_scheme_phi(1)=1.d0
      case (2)
        xip(1)=xi(1)/p(1)
        mitc_interpolation_scheme_phi(1)=0.5d0*(1.d0-xip(1))
        mitc_interpolation_scheme_phi(2)=0.5d0*(1.d0+xip(1))
      case (3)
        xip(2)=xi(2)/p(2)
        mitc_interpolation_scheme_phi(1)=0.5d0*(1.d0-xip(2))
        mitc_interpolation_scheme_phi(2)=0.5d0*(1.d0+xip(2))
      case (4)
        xip=xi(1:2)/p(1:2)
        aux(1)=0.25d0-0.25d0*xip(1)
        aux(2)=0.25d0+0.25d0*xip(1)
        aux(3)=1.d0-xip(2)
        aux(4)=1.d0+xip(2)
        mitc_interpolation_scheme_phi(1)=aux(1)*aux(3)
        mitc_interpolation_scheme_phi(2)=aux(2)*aux(3)
        mitc_interpolation_scheme_phi(3)=aux(1)*aux(4)
        mitc_interpolation_scheme_phi(4)=aux(2)*aux(4)
      case (5)
        xip=xi(1:2)/p(1:2)
        aux(1)=0.25d0-0.25d0*xip(1)
        aux(2)=0.25d0+0.25d0*xip(1)
        aux(3)=1.d0-xip(2)
        aux(4)=1.d0+xip(2)
        aux(5)=0.25d0*(1.d0-xip(1)**2)*(1.d0-xip(2)**2)
        mitc_interpolation_scheme_phi(1)=aux(1)*aux(3)-aux(5)
        mitc_interpolation_scheme_phi(2)=aux(2)*aux(3)-aux(5)
        mitc_interpolation_scheme_phi(3)=aux(1)*aux(4)-aux(5)
        mitc_interpolation_scheme_phi(4)=aux(2)*aux(4)-aux(5)
        mitc_interpolation_scheme_phi(5)=4.d0*aux(5)
      case (6)
        xip=xi(1:2)/p(1:2)
        aux(1)=1.d0-xip(1)
        aux(2)=1.d0+xip(1)
        aux(3)=1.d0-xip(2)
        aux(4)=1.d0+xip(2)
        mitc_interpolation_scheme_phi(1)=-0.25d0*xip(1)*aux(1)*aux(3)
        mitc_interpolation_scheme_phi(2)= 0.25d0*xip(1)*aux(2)*aux(3)
        mitc_interpolation_scheme_phi(3)= 0.50d0*aux(1)*aux(2)*aux(3)
        mitc_interpolation_scheme_phi(4)=-0.25d0*xip(1)*aux(1)*aux(4)
        mitc_interpolation_scheme_phi(5)= 0.25d0*xip(1)*aux(2)*aux(4)
        mitc_interpolation_scheme_phi(6)= 0.50d0*aux(1)*aux(2)*aux(4)
      case (7)
        xip=xi(1:2)/p(1:2)
        aux(1)=1.d0-xip(1)
        aux(2)=1.d0+xip(1)
        aux(3)=1.d0-xip(2)
        aux(4)=1.d0+xip(2)
        mitc_interpolation_scheme_phi(1)=-0.25d0*aux(1)*xip(2)*aux(3)
        mitc_interpolation_scheme_phi(2)=-0.25d0*aux(2)*xip(2)*aux(3)
        mitc_interpolation_scheme_phi(3)= 0.25d0*aux(1)*xip(2)*aux(4)
        mitc_interpolation_scheme_phi(4)= 0.25d0*aux(2)*xip(2)*aux(4)
        mitc_interpolation_scheme_phi(5)= 0.50d0*aux(1)*aux(3)*aux(4)
        mitc_interpolation_scheme_phi(6)= 0.50d0*aux(2)*aux(3)*aux(4)
      case default
        stop 'ERROR: mitc_interpolation_scheme does not recognize this interpolation'
    end select
  end function mitc_interpolation_scheme_phi

!  subroutine testmitc()
!    integer           :: t       !! Type of interpolation
!    real(kind=real64) :: p(2)    !! Parameters for the interpolation
!    integer           :: n       !! Number of tying points
!    real(kind=real64) :: xi(2,6) !! Local coordinates of each interpolation point
!    integer           :: i, j1, j2
!    real(kind=real64) :: phi(6), xic(2)
!    t   =7
!    p(1)=0.5d0
!    p(2)=0.8d0
!    call mitc_interpolation_scheme_tp(t,p,n,xi)
!    do i=1,n
!      write(33,*) xi(:,i)
!    end do
!    write(34,*) -1.,-1., 0.
!    write(34,*)  1.,-1., 0.
!    write(34,*)  1., 1., 0.
!    write(34,*) -1., 1., 0.
!    write(34,*) -1.,-1., 0.
!    call mitc_interpolation_scheme_tp(t,p,n,xi)
!    do i=1,n
!      do j1=0,100
!        do j2=0,100
!          xic(1)=-1.d0+2.d0*dble(j1)/100.d0
!          xic(2)=-1.d0+2.d0*dble(j2)/100.d0
!          phi=mitc_interpolation_scheme_phi(t,p,xic)
!          write(35,*) xic(1), xic(2), phi(i)
!        end do
!      end do
!      write(35,*)
!      write(35,*)
!      do j1=1,n
!        if (j1.eq.i) then
!          write(36,*) xi(:,j1), 1.
!        else
!          write(36,*) xi(:,j1), 0.
!        end if
!      end do
!      write(36,*)
!      write(36,*)
!    end do
!! gnuplot file
!!set xrange [-1.5:1.5]
!!set yrange [-1.5:1.5]
!!set size square
!!set grid x y mx my
!!plot 'fort.33' u 1:2 w p pt 2 t "Tying points", \
!!     'fort.34' u 1:2 w l lc 7 lw 2 t "Element"
!!pause -1
!!set view equal xyz
!!set view 60,45
!!set xlabel "xi1"
!!set ylabel "xi2"
!!set grid x y mx my
!!do for [i=0:5] {
!!str=sprintf("Tying point %d",i+1);
!!set title str
!!splot 'fort.34' u 1:2:3 w l lc 7 lw 2 t "Element", \
!!      'fort.35' index i u 1:2:3 w p pt 0 t "Shape function", \
!!      'fort.36' index i u 1:2:3 w p pt 2 t "Tying points (with s.f. value)"
!!pause -1
!!}
!  end subroutine testmitc

  !! Calculate the stiffness matrix K for statics, with real E and K. MITC (Bathe) locking-free formulation.
  subroutine fbem_fem_mitcdegshell_K_real(etype,x_mn,v_mn,t_mn,Em,nu,kappa,ngpip,ngpth,K,V)
    implicit none
    ! I/O
    integer           :: etype                                          !! Type of element (displacements interpolation): tri3, tri6, quad4, quad8, quad9.
    real(kind=real64) :: x_mn(3,fbem_n_nodes(etype))                    !! Position vectors of the mid-plane nodes.
    real(kind=real64) :: v_mn(3,3,fbem_n_nodes(etype))                  !! Local axes for each mid-node for the rotation degrees of freedom.
    real(kind=real64) :: t_mn(fbem_n_nodes(etype))                      !! Thickness of each mid-node in the v_3 direction.
    real(kind=real64) :: Em                                             !! Young's modulus
    real(kind=real64) :: nu                                             !! Poisson's ratio
    real(kind=real64) :: kappa(3)                                       !! Shear correction factors: kx', ky',-
    integer           :: ngpip                                          !! Number of Gauss-Legendre integration points for in-plane coordinates (xi1,xi2) for the membrane-bending (inplane) local strain contribution.
    integer           :: ngpth                                          !! Number of Gauss-Legendre integration points for thickness coordinate (xi3)
    real(kind=real64) :: K(5*fbem_n_nodes(etype),5*fbem_n_nodes(etype)) !! Stiffness matrix
    real(kind=real64) :: V                                              !! Volume of the element
    ! Local
    integer           :: n_mn                                  ! Number of mid-nodes
    integer           :: kmn                                   ! Counter of mid-nodes
    integer           :: contribution                          ! Contribution part
    integer           :: ngp                                   ! Number of Gauss points
    integer           :: rule                                  ! Rule of Wandzura quadrature
    integer           :: kxi1, kxi2, kxi3, kxit, ksf           ! Integration points counters
    real(kind=real64) :: xi1, xi2, xi3, xi(2), w1, w2, w3, wt  ! Curvilinear coordinates and quadrature weights
    real(kind=real64) :: aux(10)                               ! Auxiliary variable needed for shape_functions module resources
    real(kind=real64) :: phi(fbem_n_nodes(etype))              ! phi shape functions
    real(kind=real64) :: dphidxi1(fbem_n_nodes(etype))         ! phi shape functions derivatives with respect to xi_1
    real(kind=real64) :: dphidxi2(fbem_n_nodes(etype))         ! phi shape functions derivatives with respect to xi_2
    real(kind=real64) :: dphidxi3(fbem_n_nodes(etype))         ! phi shape functions derivatives with respect to xi_3
    real(kind=real64) :: varphi(fbem_n_nodes(etype))           ! varphi shape functions
    real(kind=real64) :: dvarphidxi1(fbem_n_nodes(etype))      ! varphi shape functions derivatives with respect to xi_1
    real(kind=real64) :: dvarphidxi2(fbem_n_nodes(etype))      ! varphi shape functions derivatives with respect to xi_2
    real(kind=real64) :: dvarphidxi3(fbem_n_nodes(etype))      ! varphi shape functions derivatives with respect to xi_3
    real(kind=real64) :: J(3,3), H(3,3), detJ                  ! Jacobian matrix, its inverse and the jacobian determinant
    real(kind=real64) :: jw                                    ! det(J) * weights
    real(kind=real64) :: T1(3), T2(3), N(3)                    ! Derivatives of position with respect to curvilinear coordinates and the normal vector to the mid-plane
    real(kind=real64) :: ep1(3), ep2(3), ep3(3)                ! Local ortogonal axes
    real(kind=real64) :: E(5,6)                                ! E matrix (global cartesian to local cartesian rotation matrix for tensors)
    real(kind=real64) :: G(6,5)                                ! G matrix (curvilinear to global cartesian rotation matrix for tensors)
    real(kind=real64) :: cB(5,5)                               ! Covariant nodal B matrix
    real(kind=real64) :: B(6,5,fbem_n_nodes(etype))            ! B matrix (global cartesian coordinates)
    real(kind=real64) :: Dp(5,5)                               ! D' constitutive matrix (cartesian local coordinates)
    real(kind=real64) :: D(6,6)                                ! D constitutive matrix (cartesian global coordinates)
    integer           :: ki, kis, kie, kj, kjs, kje, ksc       ! Counters and nodal DOF limits
    real(kind=real64) :: gv1(3), gv2(3), gv3(3)                ! Covariant basis vectors
    real(kind=real64) :: gn1(3), gn2(3), gn3(3)                ! Contravariant basis vectors
    real(kind=real64) :: dNdxi1(3,5), dNdxi2(3,5), dNdxi3(3,5)
    ! Covariant strains are ordered as: in-layer strains (e11, e22, e12), transverse shear strains (e13, e23)
    integer           :: itype(5)      ! Interpolation scheme of each strain component
    real(kind=real64) :: ipars(2,5)    ! Parameters for custom positioning of tying points
    integer           :: n_tp(5)       ! Number of tying points of each covariant strain component
    real(kind=real64) :: xi_tp(2,6,5)  ! Position in curvilinear coordinates tying points
    real(kind=real64) :: phi_tp(6,5)   ! Shape functions for strain interpolation
    !
    ! Covariant B_ij matrix (B11,B22,B12,B13,B23) with 5 nodal DOF for each node k at each tying point (surface, thickness).
    ! Index 1: nodal DOF (u1,u2,u3,alpha,beta)
    ! Index 2: node (1,2,...,N)
    ! Index 3: thickness point index
    ! Index 4: surface point index
    ! Index 5: covariant strain component (e11,e22,e12,e13,e23)
    !
    real(kind=real64) :: cBtp(5,fbem_n_nodes(etype),ngpth,6,5)
    !
    ! Initialization
    !
    K=0
    V=0
    n_mn=fbem_n_nodes(etype)
    itype=0
    ipars=0
    !
    ! Local constitutive matrix D'
    !
    Dp=0.d0
    Dp(1,1)=1.d0
    Dp(1,2)=nu
    Dp(2,1)=nu
    Dp(2,2)=1.d0
    Dp(3,3)=0.5d0*(1.d0-nu)
    Dp(4,4)=kappa(1)*0.5d0*(1.d0-nu)
    Dp(5,5)=kappa(2)*0.5d0*(1.d0-nu)
    Dp=Em/(1.d0-nu**2)*Dp
    !
    ! Switch between triangular and quadrilateral elements
    !
    select case (etype)
      !
      ! Triangular elements
      !
      case (fbem_tri3,fbem_tri6)
        stop 'MITC element not available'
      !
      ! Quadrilateral elements
      !
      case (fbem_quad4,fbem_quad8,fbem_quad9)
        select case (etype)
          case (fbem_quad4)
            ! Standard MITC4 (Dvorkin & Bathe, 1984)
            ! eps_13
            itype(  4)=3
            ipars(:,4)=[0.d0,1.d0]
            ! eps_23
            itype(  5)=2
            ipars(:,5)=[1.d0,0.d0]
!            ! MITC4b (Dvorkin & Bathe element but with 1/sqrt(3))
!            ! eps_13
!            itype(  4)=3
!            ipars(:,4)=[0.d0,sqrt(1.d0/3.d0)]
!            ! eps_23
!            itype(  5)=2
!            ipars(:,5)=[sqrt(1.d0/3.d0),0.d0]
!            ! MITC4m (analogy of MITC9)
!            ! eps_11
!            itype(  1)=3
!            ipars(:,1)=[0.d0,sqrt(1.d0/3.d0)]
!            ! eps_22
!            itype(  2)=2
!            ipars(:,2)=[sqrt(1.d0/3.d0),0.d0]
!            ! eps_12
!            itype(  3)=1
!            ipars(:,3)=[0.d0,0.d0]
!            ! eps_13
!            itype(  4)=itype(  1)
!            ipars(:,4)=ipars(:,1)
!            ! eps_23
!            itype(  5)=itype(  2)
!            ipars(:,5)=ipars(:,2)
          case (fbem_quad9)
            !
            ! Standard MITC9 (Bucalem & Bathe, 1993)
            !
            ! eps_11
            itype(  1)=7
            ipars(:,1)=[sqrt(1.d0/3.d0),sqrt(3.d0/5.d0)]
            ! eps_22
            itype(  2)=6
            ipars(:,2)=[sqrt(3.d0/5.d0),sqrt(1.d0/3.d0)]
            ! eps_12
            itype(  3)=4
            ipars(:,3)=[sqrt(1.d0/3.d0),sqrt(1.d0/3.d0)]
            ! eps_13
            itype(  4)=7
            ipars(:,4)=[sqrt(1.d0/3.d0),sqrt(3.d0/5.d0)]
            ! eps_23
            itype(  5)=6
            ipars(:,5)=[sqrt(3.d0/5.d0),sqrt(1.d0/3.d0)]
!~             !
!~             ! MITC9b (Bathe et al, 2003)
!~             !
!~             ! eps_11
!~             itype(  1)=7
!~             ipars(:,1)=[sqrt(1.d0/3.d0),sqrt(3.d0/5.d0)]
!~             ! eps_22
!~             itype(  2)=6
!~             ipars(:,2)=[sqrt(3.d0/5.d0),sqrt(1.d0/3.d0)]
!~             ! eps_12
!~             itype(  3)=4
!~             ipars(:,3)=[sqrt(1.d0/3.d0),sqrt(1.d0/3.d0)]
!~             ! eps_13
!~             itype(  4)=7
!~             ipars(:,4)=[sqrt(1.d0/3.d0),           1.d0]
!~             ! eps_23
!~             itype(  5)=6
!~             ipars(:,5)=[           1.d0,sqrt(1.d0/3.d0)]
          case default
            stop 'MITC element not available'
        end select
        !
        ! Loop through each covariant strain component
        !
        do ksc=1,5
          !
          ! Initialize
          !
          if (itype(ksc).gt.0) then
            call mitc_interpolation_scheme_tp(itype(ksc),ipars(:,ksc),n_tp(ksc),xi_tp(:,:,ksc))
          else
            n_tp(ksc)=0.d0
            xi_tp(:,:,ksc)=0.d0
          end if
          !
          ! Loop through each tying point
          !
          do ksf=1,n_tp(ksc)
            ! xi_1, xi_2
            xi=xi_tp(:,ksf,ksc)
            ! In-plane shape functions and their first derivatives with respect to xi_1, xi_2 and xi_3 at (xi_1,xi_2,xi_3)
#           define delta 0.0d0
#           include <phi_and_dphidxik_2d.rc>
#           undef delta
            dphidxi3=0.d0
            do kxi3=1,ngpth
              ! xi_3
              xi3=gl11_xi(kxi3,ngpth)
              ! Thickness shape function and its derivative with respect to xi_1, xi_2 and xi_3 at (xi_1,xi_2,xi_3)
              varphi=phi*0.5d0*xi3*t_mn
              dvarphidxi1=dphidxi1*0.5d0*xi3*t_mn
              dvarphidxi2=dphidxi2*0.5d0*xi3*t_mn
              dvarphidxi3=phi*0.5d0*t_mn
              ! Calculate Jacobian matrix at (xi_1,xi_2,xi_3)
              J=0.d0
              do kmn=1,n_mn
                J(1,:)=J(1,:)+dphidxi1(kmn)*x_mn(:,kmn)+dvarphidxi1(kmn)*v_mn(:,3,kmn)
                J(2,:)=J(2,:)+dphidxi2(kmn)*x_mn(:,kmn)+dvarphidxi2(kmn)*v_mn(:,3,kmn)
                J(3,:)=J(3,:)+dphidxi3(kmn)*x_mn(:,kmn)+dvarphidxi3(kmn)*v_mn(:,3,kmn)
              end do
              ! Calculate inv(J) and det(J)
              call fbem_invert_3x3_matrix(J,H,detJ)
              ! Covariant basis
              gv1=J(1,:)
              gv2=J(2,:)
              gv3=J(3,:)
              ! Build covariant B matrices
              dNdxi1=0.d0
              dNdxi2=0.d0
              dNdxi3=0.d0
              do kmn=1,n_mn
                ! dN/dxi
                dNdxi1(  1,1)= dphidxi1(kmn)
                dNdxi1(  2,2)= dphidxi1(kmn)
                dNdxi1(  3,3)= dphidxi1(kmn)
                dNdxi1(1:3,4)= dvarphidxi1(kmn)*v_mn(:,1,kmn)
                dNdxi1(1:3,5)=-dvarphidxi1(kmn)*v_mn(:,2,kmn)
                dNdxi2(  1,1)= dphidxi2(kmn)
                dNdxi2(  2,2)= dphidxi2(kmn)
                dNdxi2(  3,3)= dphidxi2(kmn)
                dNdxi2(1:3,4)= dvarphidxi2(kmn)*v_mn(:,1,kmn)
                dNdxi2(1:3,5)=-dvarphidxi2(kmn)*v_mn(:,2,kmn)
                dNdxi3(  1,1)= dphidxi3(kmn)
                dNdxi3(  2,2)= dphidxi3(kmn)
                dNdxi3(  3,3)= dphidxi3(kmn)
                dNdxi3(1:3,4)= dvarphidxi3(kmn)*v_mn(:,1,kmn)
                dNdxi3(1:3,5)=-dvarphidxi3(kmn)*v_mn(:,2,kmn)
                ! Save
                select case (ksc)
                  case (1)
                    cBtp(:,kmn,kxi3,ksf,1)=matmul(gv1,dNdxi1)
                  case (2)
                    cBtp(:,kmn,kxi3,ksf,2)=matmul(gv2,dNdxi2)
                  case (3)
                    cBtp(:,kmn,kxi3,ksf,3)=0.5d0*(matmul(gv2,dNdxi1)+matmul(gv1,dNdxi2))
                  case (4)
                    cBtp(:,kmn,kxi3,ksf,4)=0.5d0*(matmul(gv3,dNdxi1)+matmul(gv1,dNdxi3))
                  case (5)
                    cBtp(:,kmn,kxi3,ksf,5)=0.5d0*(matmul(gv3,dNdxi2)+matmul(gv2,dNdxi3))
                end select
              end do
            end do ! Thickness
          end do ! Surface
        end do ! Strain component
        !
        ! Numerical integration
        !
        do kxi1=1,ngpip
          xi1=gl11_xi(kxi1,ngpip)
          w1=gl11_w(kxi1,ngpip)
          do kxi2=1,ngpip
            xi2=gl11_xi(kxi2,ngpip)
            w2=gl11_w(kxi2,ngpip)
            !
            ! In-plane shape functions and their first derivatives with respect to xi_1, xi_2 and xi_3 at (xi_1,xi_2,xi_3)
            ! Displacement interpolation
            !
            xi(1)=xi1
            xi(2)=xi2
#           define delta 0.0d0
#           include <phi_and_dphidxik_2d.rc>
#           undef delta
            dphidxi3=0.d0
            !
            ! Shape functions of the substitute strains intepolations
            !
            phi_tp=0.d0
            do ksc=1,5
              if (itype(ksc).gt.0) phi_tp(:,ksc)=mitc_interpolation_scheme_phi(itype(ksc),ipars(:,ksc),xi)
            end do
            ! Thickness direction
            do kxi3=1,ngpth
              xi3=gl11_xi(kxi3,ngpth)
              w3=gl11_w(kxi3,ngpth)
              !
              ! Thickness shape function and its derivative with respect to xi_1, xi_2 and xi_3 at (xi_1,xi_2,xi_3)
              ! Displacement interpolation
              !
              varphi=phi*0.5d0*xi3*t_mn
              dvarphidxi1=dphidxi1*0.5d0*xi3*t_mn
              dvarphidxi2=dphidxi2*0.5d0*xi3*t_mn
              dvarphidxi3=phi*0.5d0*t_mn
              ! Calculate position vector x, and Jacobian matrix at (xi_1,xi_2,xi_3)
              J=0.d0
              do kmn=1,n_mn
                J(1,:)=J(1,:)+dphidxi1(kmn)*x_mn(:,kmn)+dvarphidxi1(kmn)*v_mn(:,3,kmn)
                J(2,:)=J(2,:)+dphidxi2(kmn)*x_mn(:,kmn)+dvarphidxi2(kmn)*v_mn(:,3,kmn)
                J(3,:)=J(3,:)+dphidxi3(kmn)*x_mn(:,kmn)+dvarphidxi3(kmn)*v_mn(:,3,kmn)
              end do
              ! Calculate inv(J) and det(J)
              call fbem_invert_3x3_matrix(J,H,detJ)
              ! Covariant basis
              gv1=J(1,:)
              gv2=J(2,:)
              gv3=J(3,:)
              ! Contravariant basis
              gn1=H(:,1)
              gn2=H(:,2)
              gn3=H(:,3)
              ! Calculate local orthogonal system of coordinates (ep_1,ep_2,ep_3) at (xi_1,xi_2,xi_3)
              ! Tangents T1 and T2
              T1=J(1,:)
              T2=J(2,:)
              ! Calculate N (normal vector) as T1 x T2 at (xi_1,xi_2,0)
              N(1)=T1(2)*T2(3)-T1(3)*T2(2)
              N(2)=T1(3)*T2(1)-T1(1)*T2(3)
              N(3)=T1(1)*T2(2)-T1(2)*T2(1)
              ! ep_3 = n
              ep3=N/sqrt(dot_product(N,N))
              ! ep_1 = t1
              ep1=T1/sqrt(dot_product(T1,T1))
              ! ep_2 = ep_3 x ep_1
              ep2(1)=ep3(2)*ep1(3)-ep3(3)*ep1(2)
              ep2(2)=ep3(3)*ep1(1)-ep3(1)*ep1(3)
              ep2(3)=ep3(1)*ep1(2)-ep3(2)*ep1(1)
              ! Global (x) to local (x') tensor transformation matrix
              E=0.d0
              E(1,1:3)=ep1**2
              E(1,4)=ep1(1)*ep1(2)
              E(1,5)=ep1(2)*ep1(3)
              E(1,6)=ep1(1)*ep1(3)
              E(2,1:3)=ep2**2
              E(2,4)=ep2(1)*ep2(2)
              E(2,5)=ep2(2)*ep2(3)
              E(2,6)=ep2(1)*ep2(3)
              E(3,1)=ep1(1)*ep2(1)
              E(3,2)=ep1(2)*ep2(2)
              E(3,3)=ep1(3)*ep2(3)
              E(4,1)=ep1(1)*ep3(1)
              E(4,2)=ep1(2)*ep3(2)
              E(4,3)=ep1(3)*ep3(3)
              E(5,1)=ep2(1)*ep3(1)
              E(5,2)=ep2(2)*ep3(2)
              E(5,3)=ep2(3)*ep3(3)
              E(3:5,1:3)=2.d0*E(3:5,1:3)
              E(3,4)=ep1(1)*ep2(2)+ep1(2)*ep2(1)
              E(3,5)=ep1(2)*ep2(3)+ep1(3)*ep2(2)
              E(3,6)=ep1(1)*ep2(3)+ep1(3)*ep2(1)
              E(4,4)=ep1(1)*ep3(2)+ep1(2)*ep3(1)
              E(4,5)=ep1(2)*ep3(3)+ep1(3)*ep3(2)
              E(4,6)=ep1(1)*ep3(3)+ep1(3)*ep3(1)
              E(5,4)=ep2(1)*ep3(2)+ep2(2)*ep3(1)
              E(5,5)=ep2(2)*ep3(3)+ep2(3)*ep3(2)
              E(5,6)=ep2(1)*ep3(3)+ep2(3)*ep3(1)
              ! Derivative transformation matrix for curvilinear to global cartesian tensor transformation
              G=0.d0
              G(1:3,1)=gn1*gn1
              G(1:3,2)=gn2*gn2
              G(1:3,3)=2.d0*gn1*gn2
              G(1:3,4)=2.d0*gn1*gn3
              G(1:3,5)=2.d0*gn2*gn3
              G(  4,1)=gn1(1)*gn1(2)
              G(  4,2)=gn2(1)*gn2(2)
              G(  4,3)=gn1(1)*gn2(2)+gn2(1)*gn1(2)
              G(  4,4)=gn1(1)*gn3(2)+gn3(1)*gn1(2)
              G(  4,5)=gn2(1)*gn3(2)+gn3(1)*gn2(2)
              G(  5,1)=gn1(2)*gn1(3)
              G(  5,2)=gn2(2)*gn2(3)
              G(  5,3)=gn1(2)*gn2(3)+gn2(2)*gn1(3)
              G(  5,4)=gn1(2)*gn3(3)+gn3(2)*gn1(3)
              G(  5,5)=gn2(2)*gn3(3)+gn3(2)*gn2(3)
              G(  6,1)=gn1(1)*gn1(3)
              G(  6,2)=gn2(1)*gn2(3)
              G(  6,3)=gn1(1)*gn2(3)+gn2(1)*gn1(3)
              G(  6,4)=gn1(1)*gn3(3)+gn3(1)*gn1(3)
              G(  6,5)=gn2(1)*gn3(3)+gn3(1)*gn2(3)
              G(4:6,:)=2.d0*G(4:6,:)
              ! Build covariant B matrices
              do kmn=1,n_mn
                cB=0.
                do ksc=1,5
                  if (itype(ksc).eq.0) then
                    ! dN/dxi
                    dNdxi1=0.d0
                    dNdxi2=0.d0
                    dNdxi3=0.d0
                    dNdxi1(  1,1)= dphidxi1(kmn)
                    dNdxi1(  2,2)= dphidxi1(kmn)
                    dNdxi1(  3,3)= dphidxi1(kmn)
                    dNdxi1(1:3,4)= dvarphidxi1(kmn)*v_mn(:,1,kmn)
                    dNdxi1(1:3,5)=-dvarphidxi1(kmn)*v_mn(:,2,kmn)
                    dNdxi2(  1,1)= dphidxi2(kmn)
                    dNdxi2(  2,2)= dphidxi2(kmn)
                    dNdxi2(  3,3)= dphidxi2(kmn)
                    dNdxi2(1:3,4)= dvarphidxi2(kmn)*v_mn(:,1,kmn)
                    dNdxi2(1:3,5)=-dvarphidxi2(kmn)*v_mn(:,2,kmn)
                    dNdxi3(  1,1)= dphidxi3(kmn)
                    dNdxi3(  2,2)= dphidxi3(kmn)
                    dNdxi3(  3,3)= dphidxi3(kmn)
                    dNdxi3(1:3,4)= dvarphidxi3(kmn)*v_mn(:,1,kmn)
                    dNdxi3(1:3,5)=-dvarphidxi3(kmn)*v_mn(:,2,kmn)
                    ! Displacement-based strains
                    select case (ksc)
                      case (1)
                        cB(1,:)=matmul(gv1,dNdxi1)
                      case (2)
                        cB(2,:)=matmul(gv2,dNdxi2)
                      case (3)
                        cB(3,:)=0.5d0*(matmul(gv2,dNdxi1)+matmul(gv1,dNdxi2))
                      case (4)
                        cB(4,:)=0.5d0*(matmul(gv3,dNdxi1)+matmul(gv1,dNdxi3))
                      case (5)
                        cB(5,:)=0.5d0*(matmul(gv3,dNdxi2)+matmul(gv2,dNdxi3))
                    end select
                  else
                    ! Perform interpolation using assumed strains
                    do ksf=1,n_tp(ksc)
                      cB(ksc,:)=cB(ksc,:)+phi_tp(ksf,ksc)*cBtp(:,kmn,kxi3,ksf,ksc)
                    end do
                  end if
                end do
                B(:,:,kmn)=matmul(G,cB)
              end do
              ! det(J) * weights
              jw=detJ*w1*w2*w3
              ! Volume
              V=V+jw
              ! Constitutive matrix D (global coordinates)
              D=matmul(transpose(E),matmul(Dp,E))
              ! Build the element stiffness matrix
              do ki=1,n_mn
                kis=(ki-1)*5+1
                kie=kis+4
                do kj=1,n_mn
                  kjs=(kj-1)*5+1
                  kje=kjs+4
                  K(kis:kie,kjs:kje)=K(kis:kie,kjs:kje)+matmul(transpose(B(:,:,ki)),matmul(D,B(:,:,kj)))*jw
                end do
              end do
            end do ! xi_3
          end do ! xi_2
        end do ! xi_1
      case default
        call fbem_error_message(error_unit,0,__FILE__,__LINE__,'etype={tri3,tri6,quad4,quad8,quad9}')
    end select
  end subroutine fbem_fem_mitcdegshell_K_real

  !! Calculate the mass matrix M
  subroutine fbem_fem_degshell_M(etype,x_midnodes,v_midnode,t_midnodes,rho,ngp,ngpth,M)
    implicit none
    ! I/O
    integer           :: etype                                          !! Type of element (displacements interpolation): tri3, tri6, quad4, quad8, quad9.
    real(kind=real64) :: x_midnodes(3,fbem_n_nodes(etype))              !! Position vectors of the mid-plane nodes.
    real(kind=real64) :: v_midnode(3,3,fbem_n_nodes(etype))            !! Local axes for each mid-node for the rotation degrees of freedom.
    real(kind=real64) :: t_midnodes(fbem_n_nodes(etype))                !! Thickness of each mid-node in the v_3 direction.
    real(kind=real64) :: rho                                            !! Young's modulus
    integer           :: ngp                                            !! Number of Gauss-Legendre integration points for the plane coordinates.
    integer           :: ngpth                                          !! Number of Gauss-Legendre integration points for thickness coordinate (xi3)
    real(kind=real64) :: M(5*fbem_n_nodes(etype),5*fbem_n_nodes(etype)) !! Mass matrix
    ! Local
    integer           :: n_midnodes                           ! Number of mid-nodes
    integer           :: kmidnode                             ! Counter of mid-nodes
    integer           :: rule                                 ! Rule of Wandzura quadrature
    integer           :: kxi1, kxi2, kxi3, kxit               ! Integration points counters
    real(kind=real64) :: xi1, xi2, xi3, xi(2), w1, w2, w3, wt ! Curvilinear coordinates and quadrature weights
    real(kind=real64) :: aux(10)                              ! Auxiliary variable needed for shape_functions module resources
    real(kind=real64) :: phi(fbem_n_nodes(etype))             ! phi shape functions
    real(kind=real64) :: dphidxi1(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_1
    real(kind=real64) :: dphidxi2(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_2
    real(kind=real64) :: dphidxi3(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_3
    real(kind=real64) :: varphi(fbem_n_nodes(etype))          ! varphi shape functions
    real(kind=real64) :: dvarphidxi1(fbem_n_nodes(etype))     ! varphi shape functions derivatives with respect to xi_1
    real(kind=real64) :: dvarphidxi2(fbem_n_nodes(etype))     ! varphi shape functions derivatives with respect to xi_2
    real(kind=real64) :: dvarphidxi3(fbem_n_nodes(etype))     ! varphi shape functions derivatives with respect to xi_3
    !real(kind=real64) :: x(3)                                ! Position vector of the integration point
    real(kind=real64) :: J(3,3), H(3,3), detJ                 ! Jacobian matrix, its inverse and the jacobian determinant
    real(kind=real64) :: jw                                   ! det(J) * weights
    real(kind=real64) :: Ne(3,5*fbem_n_nodes(etype))          ! E matrix
    integer           :: ki                                   ! Counters and nodal DOF limits
    !
    ! Initialization
    !
    ! Initialize mass matrix
    M=0.d0
    ! Number of mid-nodes
    n_midnodes=fbem_n_nodes(etype)
    !
    ! Switch between triangular and quadrilateral elements
    !
    select case (etype)
      !
      ! Triangular elements
      !
      case (fbem_tri3,fbem_tri6)
        !
        ! Loops through integration points
        !
        ! Transform to order for Wandzura rules
        rule=2*ngp-1
        do kxit=1,wantri_n(rule)
          ! xi_1, xi_2 and w_t
          xi1=wantri_xi1(kxit,rule)
          xi2=wantri_xi2(kxit,rule)
          wt=wantri_w(kxit,rule)
          do kxi3=1,ngpth
            ! xi_3 and w_3
            xi3=gl11_xi(kxi3,ngpth)
            w3=gl11_w(kxi3,ngpth)
            ! In-plane shape functions and their first derivatives with respect to xi_1, xi_2 and xi_3 at (xi_1,xi_2,xi_3)
            xi(1)=xi1
            xi(2)=xi2
#           define delta 0.0d0
#           include <phi_and_dphidxik_2d.rc>
#           undef delta
            dphidxi3=0.d0
            ! Thickness shape function and its derivative with respect to xi_1, xi_2 and xi_3 at (xi_1,xi_2,xi_3)
            varphi=phi*0.5d0*xi3*t_midnodes
            dvarphidxi1=dphidxi1*0.5d0*xi3*t_midnodes
            dvarphidxi2=dphidxi2*0.5d0*xi3*t_midnodes
            dvarphidxi3=phi*0.5d0*t_midnodes
            ! Calculate position vector x, and Jacobian matrix at (xi_1,xi_2,xi_3)
            !x=0.d0
            J=0.d0
            do kmidnode=1,n_midnodes
              !x=x+phi(kmidnode)*x_midnodes(:,kmidnode)+varphi(kmidnode)*v_midnode(:,3,kmidnode)
              J(1,:)=J(1,:)+dphidxi1(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi1(kmidnode)*v_midnode(:,3,kmidnode)
              J(2,:)=J(2,:)+dphidxi2(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi2(kmidnode)*v_midnode(:,3,kmidnode)
              J(3,:)=J(3,:)+dphidxi3(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi3(kmidnode)*v_midnode(:,3,kmidnode)
            end do
            ! Calculate inv(J) and det(J)
            call fbem_invert_3x3_matrix(J,H,detJ)
            ! Build matrix Ne (shape functions matrix)
            Ne=0.d0
            do kmidnode=1,n_midnodes
              ki=(kmidnode-1)*5+1
              Ne(1,ki  )= phi(kmidnode)
              Ne(2,ki+1)= phi(kmidnode)
              Ne(3,ki+2)= phi(kmidnode)
              Ne(:,ki+3)= varphi(kmidnode)*v_midnode(:,1,kmidnode)
              Ne(:,ki+4)=-varphi(kmidnode)*v_midnode(:,2,kmidnode)
            end do
            ! det(J) * weights
            jw=detJ*wt*w3
            ! Add
            M=M+matmul(transpose(Ne),Ne)*jw
          end do ! xi_3
        end do ! xi_1 and xi_2
      !
      ! Quadrilateral elements
      !
      case (fbem_quad4,fbem_quad8,fbem_quad9)
        !
        ! Loops through integration points
        !
        do kxi1=1,ngp
          ! xi_1 and w_1
          xi1=gl11_xi(kxi1,ngp)
          w1=gl11_w(kxi1,ngp)
          do kxi2=1,ngp
            ! xi_2 and w_2
            xi2=gl11_xi(kxi2,ngp)
            w2=gl11_w(kxi2,ngp)
            do kxi3=1,ngpth
              ! xi_3 and w_3
              xi3=gl11_xi(kxi3,ngpth)
              w3=gl11_w(kxi3,ngpth)
              ! In-plane shape functions and their first derivatives with respect to xi_1, xi_2 and xi_3 at (xi_1,xi_2,xi_3)
              xi(1)=xi1
              xi(2)=xi2
#             define delta 0.0d0
#             include <phi_and_dphidxik_2d.rc>
#             undef delta
              dphidxi3=0.d0
              ! Thickness shape function and its derivative with respect to xi_1, xi_2 and xi_3 at (xi_1,xi_2,xi_3)
              varphi=phi*0.5d0*xi3*t_midnodes
              dvarphidxi1=dphidxi1*0.5d0*xi3*t_midnodes
              dvarphidxi2=dphidxi2*0.5d0*xi3*t_midnodes
              dvarphidxi3=phi*0.5d0*t_midnodes
              ! Calculate position vector x, and Jacobian matrix at (xi_1,xi_2,xi_3)
              !x=0.d0
              J=0.d0
              do kmidnode=1,n_midnodes
                !x=x+phi(kmidnode)*x_midnodes(:,kmidnode)+varphi(kmidnode)*v_midnode(:,3,kmidnode)
                J(1,:)=J(1,:)+dphidxi1(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi1(kmidnode)*v_midnode(:,3,kmidnode)
                J(2,:)=J(2,:)+dphidxi2(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi2(kmidnode)*v_midnode(:,3,kmidnode)
                J(3,:)=J(3,:)+dphidxi3(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi3(kmidnode)*v_midnode(:,3,kmidnode)
              end do
              ! Calculate inv(J) and det(J)
              call fbem_invert_3x3_matrix(J,H,detJ)
              ! Build matrix Ne (shape functions matrix)
              Ne=0.d0
              do kmidnode=1,n_midnodes
                ki=(kmidnode-1)*5+1
                Ne(1,ki  )= phi(kmidnode)
                Ne(2,ki+1)= phi(kmidnode)
                Ne(3,ki+2)= phi(kmidnode)
                Ne(:,ki+3)= varphi(kmidnode)*v_midnode(:,1,kmidnode)
                Ne(:,ki+4)=-varphi(kmidnode)*v_midnode(:,2,kmidnode)
              end do
              ! det(J) * weights
              jw=detJ*w1*w2*w3
              ! Add
              M=M+matmul(transpose(Ne),Ne)*jw
            end do ! xi_3
          end do ! xi_2
        end do ! xi_1
      case default
        call fbem_error_message(error_unit,0,__FILE__,__LINE__,'etype={tri3,tri6,quad4,quad8,quad9}')
    end select
    ! Multiply by constant rho
    M=rho*M
  end subroutine fbem_fem_degshell_M

  !! Load matrix Q for a mid-plane distributed load (global coordinates load / global disp., local rot.)
  subroutine fbem_fem_degshell_Q(etype,x_midnodes,ngp,Q)
    implicit none
    ! I/O
    integer           :: etype                                           !! Type of element (displacements interpolation): tri3, tri6, quad4, quad8, quad9.
    real(kind=real64) :: x_midnodes(3,fbem_n_nodes(etype))               !! Position vectors of the mid-plane nodes.
    integer           :: ngp                                             !! Number of Gauss points
    real(kind=real64) :: Q(5*fbem_n_nodes(etype),5*fbem_n_nodes(etype))  !! Load matrix Q for global coordinates distributed load
    ! Local
    integer           :: n_midnodes                           ! Number of mid-nodes
    integer           :: kmidnode                             ! Counter of mid-nodes
    integer           :: rule                                 ! Rule of Wandzura quadrature
    integer           :: kxi1, kxi2, kxit                     ! Integration points counters
    real(kind=real64) :: xi(2), w1, w2, wt                    ! Curvilinear coordinates and quadrature weights
    real(kind=real64) :: aux(10)                              ! Auxiliary variable needed for shape_functions module resources
    real(kind=real64) :: phi(fbem_n_nodes(etype))             ! phi shape functions
    real(kind=real64) :: dphidxi1(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_1
    real(kind=real64) :: dphidxi2(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_2
    real(kind=real64) :: detJ                                 ! Jacobian determinant
    real(kind=real64) :: jw                                   ! det(J) * weights
    real(kind=real64) :: T1(3), T2(3), N(3)                   ! Derivatives of position with respect to curvilinear coordinates and the normal vector to the mid-plane
    real(kind=real64) :: Ne(3,5*fbem_n_nodes(etype))          ! Shape functions matrix
    integer           :: ki                                   ! Counter
    !
    ! Initialization
    !
    ! Initialize load matrix at xi3=0 (mid-plane)
    Q=0.d0
    ! Number of mid-nodes
    n_midnodes=fbem_n_nodes(etype)
    !
    ! Switch between triangular and quadrilateral elements
    !
    select case (etype)
      !
      ! Triangular elements
      !
      case (fbem_tri3,fbem_tri6)
        ! Order for Wandzura rules
        rule=2*ngp-1
        do kxit=1,wantri_n(rule)
          ! xi_1, xi_2 and w_t
          xi(1)=wantri_xi1(kxit,rule)
          xi(2)=wantri_xi2(kxit,rule)
          wt=wantri_w(kxit,rule)
          ! In-plane shape functions and their first derivatives with respect to xi_1, xi_2 at (xi_1,xi_2)
#         define delta 0.0d0
#         include <phi_and_dphidxik_2d.rc>
#         undef delta
          ! Build matrix Ne (shape functions matrix)
          Ne=0.d0
          do kmidnode=1,n_midnodes
            ki=(kmidnode-1)*5+1
            Ne(1,ki  )=phi(kmidnode)
            Ne(2,ki+1)=phi(kmidnode)
            Ne(3,ki+2)=phi(kmidnode)
          end do
          ! Calculate T1 and T2
          T1=0.d0
          T2=0.d0
          do kmidnode=1,n_midnodes
            T1=T1+dphidxi1(kmidnode)*x_midnodes(:,kmidnode)
            T2=T2+dphidxi2(kmidnode)*x_midnodes(:,kmidnode)
          end do
          ! Calculate N (normal vector) as T1 x T2 at (xi_1,xi_2,0)
          N(1)=T1(2)*T2(3)-T1(3)*T2(2)
          N(2)=T1(3)*T2(1)-T1(1)*T2(3)
          N(3)=T1(1)*T2(2)-T1(2)*T2(1)
          ! Jacobian
          detJ=sqrt(dot_product(N,N))
          ! det(J) * weights
          jw=detJ*wt
          ! Add
          Q=Q+matmul(transpose(Ne),Ne)*jw
        end do ! xi_1 and xi_2
      !
      ! Quadrilateral elements
      !
      case (fbem_quad4,fbem_quad8,fbem_quad9)
        do kxi1=1,ngp
          ! xi_1 and w_1
          xi(1)=gl11_xi(kxi1,ngp)
          w1=gl11_w(kxi1,ngp)
          do kxi2=1,ngp
            ! xi_2 and w_2
            xi(2)=gl11_xi(kxi2,ngp)
            w2=gl11_w(kxi2,ngp)
            ! In-plane shape functions and their first derivatives with respect to xi_1, xi_2 at (xi_1,xi_2)
#           define delta 0.0d0
#           include <phi_and_dphidxik_2d.rc>
#           undef delta
            ! Build matrix Ne (shape functions matrix)
            Ne=0.d0
            do kmidnode=1,n_midnodes
              ki=(kmidnode-1)*5+1
              Ne(1,ki  )=phi(kmidnode)
              Ne(2,ki+1)=phi(kmidnode)
              Ne(3,ki+2)=phi(kmidnode)
            end do
            ! Calculate T1 and T2
            T1=0.d0
            T2=0.d0
            do kmidnode=1,n_midnodes
              T1=T1+dphidxi1(kmidnode)*x_midnodes(:,kmidnode)
              T2=T2+dphidxi2(kmidnode)*x_midnodes(:,kmidnode)
            end do
            ! Calculate N (normal vector) as T1 x T2 at (xi_1,xi_2,0)
            N(1)=T1(2)*T2(3)-T1(3)*T2(2)
            N(2)=T1(3)*T2(1)-T1(1)*T2(3)
            N(3)=T1(1)*T2(2)-T1(2)*T2(1)
            ! Jacobian
            detJ=sqrt(dot_product(N,N))
            ! det(J) * weights
            jw=detJ*w1*w2
            ! Add
            Q=Q+matmul(transpose(Ne),Ne)*jw
          end do ! xi_2
        end do ! xi_1
      case default
        call fbem_error_message(error_unit,0,__FILE__,__LINE__,'etype={tri3,tri6,quad4,quad8,quad9}')
    end select
  end subroutine fbem_fem_degshell_Q

  !! Load matrix Q for a face: 1 (upper face), 0 (mid-surface),-1 (lower face); distributed load (global coordinates load / global disp., local rot.)
  subroutine fbem_fem_degshell_Q_face(etype,x_md,v_md,t_md,location,ngp,Q)
    implicit none
    ! I/O
    integer           :: etype                                          !! Type of element (displacements interpolation): tri3, tri6, quad4, quad8, quad9.
    real(kind=real64) :: x_md(3,fbem_n_nodes(etype))                    !! Position vectors of the mid-plane nodes.
    real(kind=real64) :: v_md(3,3,fbem_n_nodes(etype))                  !! Local axes for each mid-node for the rotation degrees of freedom.
    real(kind=real64) :: t_md(fbem_n_nodes(etype))                      !! Thickness of each mid-node in the v_3 direction.
    integer           :: location                                       !! Location of the load: 1 (upper face), 0 (mid-surface),-1 (lower face).
    integer           :: ngp                                            !! Number of Gauss points
    real(kind=real64) :: Q(5*fbem_n_nodes(etype),3*fbem_n_nodes(etype)) !! Load matrix Q for global coordinates distributed load
    ! Local
    integer           :: n_md                                 ! Number of mid-nodes
    integer           :: k_md                                 ! Counter of mid-nodes
    integer           :: rule                                 ! Rule of Wandzura quadrature
    integer           :: kxi1, kxi2, kxit                     ! Integration points counters
    real(kind=real64) :: xi(3), w1, w2, wt                    ! Curvilinear coordinates and quadrature weights
    real(kind=real64) :: aux(10)                              ! Auxiliary variable needed for shape_functions module resources
    real(kind=real64) :: phi(fbem_n_nodes(etype))             ! phi shape functions
    real(kind=real64) :: dphidxi1(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_1
    real(kind=real64) :: dphidxi2(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_2
    real(kind=real64) :: dphidxi3(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_3
    real(kind=real64) :: varphi(fbem_n_nodes(etype))          ! varphi shape functions
    real(kind=real64) :: dvarphidxi1(fbem_n_nodes(etype))     ! varphi shape functions derivatives with respect to xi_1
    real(kind=real64) :: dvarphidxi2(fbem_n_nodes(etype))     ! varphi shape functions derivatives with respect to xi_2
    real(kind=real64) :: dvarphidxi3(fbem_n_nodes(etype))     ! varphi shape functions derivatives with respect to xi_3
    real(kind=real64) :: dxdxi1(3), dxdxi2(3), dxdxi3(3)      ! dx/dxik
    real(kind=real64) :: jg                                   ! Geometric jacobian
    real(kind=real64) :: jw                                   ! jg * weights
    real(kind=real64) :: N(3)                                 ! Normal vector
    real(kind=real64) :: Ne(3,5*fbem_n_nodes(etype))          ! Shell FE shape functions matrix
    real(kind=real64) :: Nface(3,3*fbem_n_nodes(etype))       ! Load shape functions matrix
    integer           :: ki                                   ! Counter
    ! INITIALIZE
    ! Initialize load matrix
    Q=0.d0
    ! Location of the load
    select case (location)
      case (-1)
        xi(3)=-1.d0
      case ( 0)
        xi(3)= 0.d0
      case ( 1)
        xi(3)= 1.d0
    end select
    ! Number of mid-nodes
    n_md=fbem_n_nodes(etype)
    ! INTEGRATE
    select case (etype)
      ! TRIANGULAR ELEMENTS
      case (fbem_tri3,fbem_tri6)
        ! Order for Wandzura rules
        rule=2*ngp-1
        do kxit=1,wantri_n(rule)
          ! xi_1, xi_2 and w_t
          xi(1)=wantri_xi1(kxit,rule)
          xi(2)=wantri_xi2(kxit,rule)
          wt=wantri_w(kxit,rule)
          ! In-plane shape functions and its derivatives
#         define delta 0.0d0
#         include <phi_and_dphidxik_2d.rc>
#         undef delta
          dphidxi3=0.d0
          ! Thickness shape function and its derivative
          varphi=phi*0.5d0*xi(3)*t_md
          dvarphidxi1=dphidxi1*0.5d0*xi(3)*t_md
          dvarphidxi2=dphidxi2*0.5d0*xi(3)*t_md
          dvarphidxi3=phi*0.5d0*t_md
          ! XIP -> XI -> X TRANSFORMATIONS
          dxdxi1=0.d0
          dxdxi2=0.d0
          dxdxi3=0.d0
          do k_md=1,n_md
            dxdxi1=dxdxi1+dphidxi1(k_md)*x_md(:,k_md)+dvarphidxi1(k_md)*v_md(:,3,k_md)
            dxdxi2=dxdxi2+dphidxi2(k_md)*x_md(:,k_md)+dvarphidxi2(k_md)*v_md(:,3,k_md)
            dxdxi3=dxdxi3+dphidxi3(k_md)*x_md(:,k_md)+dvarphidxi3(k_md)*v_md(:,3,k_md)
          end do
          N=fbem_cross_product(dxdxi1,dxdxi2)
          jg=sqrt(dot_product(N,N))
          ! Build Shell FE shape function matrix
          Ne=0.d0
          do k_md=1,n_md
            ki=(k_md-1)*5
            Ne(1,ki+1)= phi(k_md)
            Ne(2,ki+2)= phi(k_md)
            Ne(3,ki+3)= phi(k_md)
            Ne(:,ki+4)= varphi(k_md)*v_md(:,1,k_md)
            Ne(:,ki+5)=-varphi(k_md)*v_md(:,2,k_md)
          end do
          ! Build load shape function matrix
          Nface=0.d0
          do k_md=1,n_md
            ki=(k_md-1)*3
            Nface(1,ki+1)=phi(k_md)
            Nface(2,ki+2)=phi(k_md)
            Nface(3,ki+3)=phi(k_md)
          end do
          ! jw * weights
          jw=jg*wt
          ! Add
          Q=Q+matmul(transpose(Ne),Nface)*jw
        end do ! xi_1 and xi_2
      ! QUADRILATERAL ELEMENTS
      case (fbem_quad4,fbem_quad8,fbem_quad9)
        do kxi1=1,ngp
          ! xi_1 and w_1
          xi(1)=gl11_xi(kxi1,ngp)
          w1=gl11_w(kxi1,ngp)
          do kxi2=1,ngp
            ! xi_2 and w_2
            xi(2)=gl11_xi(kxi2,ngp)
            w2=gl11_w(kxi2,ngp)
            ! In-plane shape functions and its derivatives
#           define delta 0.0d0
#           include <phi_and_dphidxik_2d.rc>
#           undef delta
            dphidxi3=0.d0
            ! Thickness shape function and its derivative
            varphi=phi*0.5d0*xi(3)*t_md
            dvarphidxi1=dphidxi1*0.5d0*xi(3)*t_md
            dvarphidxi2=dphidxi2*0.5d0*xi(3)*t_md
            dvarphidxi3=phi*0.5d0*t_md
            ! XIP -> XI -> X TRANSFORMATIONS
            dxdxi1=0.d0
            dxdxi2=0.d0
            dxdxi3=0.d0
            do k_md=1,n_md
              dxdxi1=dxdxi1+dphidxi1(k_md)*x_md(:,k_md)+dvarphidxi1(k_md)*v_md(:,3,k_md)
              dxdxi2=dxdxi2+dphidxi2(k_md)*x_md(:,k_md)+dvarphidxi2(k_md)*v_md(:,3,k_md)
              dxdxi3=dxdxi3+dphidxi3(k_md)*x_md(:,k_md)+dvarphidxi3(k_md)*v_md(:,3,k_md)
            end do
            N=fbem_cross_product(dxdxi1,dxdxi2)
            jg=sqrt(dot_product(N,N))
            ! Build Shell FE shape function matrix
            Ne=0.d0
            do k_md=1,n_md
              ki=(k_md-1)*5
              Ne(1,ki+1)= phi(k_md)
              Ne(2,ki+2)= phi(k_md)
              Ne(3,ki+3)= phi(k_md)
              Ne(:,ki+4)= varphi(k_md)*v_md(:,1,k_md)
              Ne(:,ki+5)=-varphi(k_md)*v_md(:,2,k_md)
            end do
            ! Build load shape function matrix
            Nface=0.d0
            do k_md=1,n_md
              ki=(k_md-1)*3
              Nface(1,ki+1)=phi(k_md)
              Nface(2,ki+2)=phi(k_md)
              Nface(3,ki+3)=phi(k_md)
            end do
            ! jg * weights
            jw=jg*w1*w2
            ! Add
            Q=Q+matmul(transpose(Ne),Nface)*jw
          end do ! xi_2
        end do ! xi_1
      case default
        call fbem_error_message(error_unit,0,__FILE__,__LINE__,'etype={tri3,tri6,quad4,quad8,quad9}')
    end select
  end subroutine fbem_fem_degshell_Q_face

  !! Load matrix Q for an edge surface distributed load (global coordinates load / global disp., local rot.)
  subroutine fbem_fem_degshell_Q_edge(etype,x_md,v_md,t_md,kedge,dtype,ngp,Q)
    implicit none
    ! I/O
    integer           :: etype                                          !! Type of mid-plane element: tri3, tri6, quad4, quad8, quad9.
    real(kind=real64) :: x_md(3,fbem_n_nodes(etype))                    !! Position vectors of the mid-plane nodes.
    real(kind=real64) :: v_md(3,3,fbem_n_nodes(etype))                  !! Local axes for each mid-node for the rotation degrees of freedom.
    real(kind=real64) :: t_md(fbem_n_nodes(etype))                      !! Thickness of each mid-node in the v_3 direction.
    integer           :: kedge                                          !! Selected edge
    integer           :: dtype                                          !! Type of edge load element (xi1 == edge local coordinate, xi2 == thickness coordinate): point1, line2point1, line3point1, etc ...
    integer           :: ngp                                            !! Number of Gauss points for edge coordinate integration
    real(kind=real64) :: Q(5*fbem_n_nodes(etype),3*fbem_n_nodes(dtype)) !! Load matrix Q for a global coordinates distributed load over an edge
    ! Local
    integer           :: n_md                                 ! Number of nodes of the midplane element
    integer           :: n_dn                                 ! Number of nodes of the load element
    integer           :: k_md                                 ! Counter of mid-nodes
    integer           :: k_dn                                 ! Counter of load nodes
    integer           :: k1, k2                               ! Integration points counters
    integer           :: ki                                   ! Counter
    real(kind=real64) :: xip(2)                               ! xip coordinates
    real(kind=real64) :: w(2)                                 ! Weights
    real(kind=real64) :: xi_e(2,2)                            ! xi coordinates of the edge
    real(kind=real64) :: xi_nodes(2,fbem_n_nodes(etype))      ! xi1,xi2 coordinates of the nodes of the element
    real(kind=real64) :: dxidxip1(2)                          ! xip->xi1,xi2 tangent
    real(kind=real64) :: xi(3)                                ! xi coordinates
    real(kind=real64) :: aux(10)                              ! Auxiliary variable needed for shape_functions module resources
    real(kind=real64) :: phi(fbem_n_nodes(etype))             ! phi shape functions
    real(kind=real64) :: dphidxi1(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_1
    real(kind=real64) :: dphidxi2(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_2
    real(kind=real64) :: dphidxi3(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_3
    real(kind=real64) :: varphi(fbem_n_nodes(etype))          ! varphi shape functions
    real(kind=real64) :: dvarphidxi1(fbem_n_nodes(etype))     ! varphi shape functions derivatives with respect to xi_1
    real(kind=real64) :: dvarphidxi2(fbem_n_nodes(etype))     ! varphi shape functions derivatives with respect to xi_2
    real(kind=real64) :: dvarphidxi3(fbem_n_nodes(etype))     ! varphi shape functions derivatives with respect to xi_3
    real(kind=real64) :: dxdxi1(3), dxdxi2(3), dxdxi3(3)      ! dx/dxik
    real(kind=real64) :: dxdxip1(3), dxdxip2(3), N(3)         ! dx/dxip
    real(kind=real64) :: jg                                   ! Area jacobian
    real(kind=real64) :: jw                                   ! jacobians * weights
    real(kind=real64) :: Ne(3,5*fbem_n_nodes(etype))          ! Shell shape functions matrix
    real(kind=real64) :: Nedge(3,3*fbem_n_nodes(dtype))       ! Shell edge load shape functions matrix
    ! Check
    if (kedge.gt.fbem_n_edges(etype)) then
      call fbem_error_message(error_unit,0,'fbem_fem_degshell_Q_edge',kedge,'invalid edge index')
    end if
    ! Initialize load matrix
    Q=0.d0
    ! Number of nodes of the midplane element
    n_md=fbem_n_nodes(etype)
    ! Number of nodes of the load element
    n_dn=fbem_n_nodes(dtype)
    ! xi1,xi2 coordinates of kedge
    xi_nodes=fbem_xi1xi2(etype,0.d0)
    xi_e(:,1)=xi_nodes(:,fbem_edge_node(1,kedge,etype))
    xi_e(:,2)=xi_nodes(:,fbem_edge_node(2,kedge,etype))
    ! Loop through xip(1)
    do k1=1,gl11_n(ngp)
      ! XIP(1) COORDINATE AND WEIGHT
      xip(1)=gl11_xi(k1,ngp)
      w(1)=gl11_w(k1,ngp)
      ! XIP(1)->XI(1),XI(2) TRANSFORMATION
      xi(1:2)=0.5d0*(1.d0-xip(1))*xi_e(:,1)+0.5d0*(1.d0+xip(1))*xi_e(:,2)
      dxidxip1=0.5d0*(xi_e(:,2)-xi_e(:,1))
      ! Loop through xip(2)
      do k2=1,gl11_n(ngp)
        ! XIP(2)==XI(3) COORDINATE AND WEIGHT
        xip(2)=gl11_xi(k2,ngp)
        w(2)=gl11_w(k2,ngp)
        ! XI(3)=XIP(2)
        xi(3)=xip(2)
        ! In-plane shape functions and its derivatives
#       define delta 0.0d0
#       include <phi_and_dphidxik_2d.rc>
#       undef delta
        dphidxi3=0.d0
        ! Thickness shape function and its derivative
        varphi=phi*0.5d0*xi(3)*t_md
        dvarphidxi1=dphidxi1*0.5d0*xi(3)*t_md
        dvarphidxi2=dphidxi2*0.5d0*xi(3)*t_md
        dvarphidxi3=phi*0.5d0*t_md
        ! XIP -> XI -> X TRANSFORMATIONS
        dxdxi1=0.d0
        dxdxi2=0.d0
        dxdxi3=0.d0
        do k_md=1,n_md
          dxdxi1=dxdxi1+dphidxi1(k_md)*x_md(:,k_md)+dvarphidxi1(k_md)*v_md(:,3,k_md)
          dxdxi2=dxdxi2+dphidxi2(k_md)*x_md(:,k_md)+dvarphidxi2(k_md)*v_md(:,3,k_md)
          dxdxi3=dxdxi3+dphidxi3(k_md)*x_md(:,k_md)+dvarphidxi3(k_md)*v_md(:,3,k_md)
        end do
        dxdxip1=dxdxi1*dxidxip1(1)+dxdxi2*dxidxip1(2)
        dxdxip2=dxdxi3
        N=fbem_cross_product(dxdxip1,dxdxip2)
        jg=sqrt(dot_product(N,N))
        ! Build shell shape function matrix Ne
        Ne=0.d0
        do k_md=1,n_md
          ki=(k_md-1)*5
          Ne(1,ki+1)= phi(k_md)
          Ne(2,ki+2)= phi(k_md)
          Ne(3,ki+3)= phi(k_md)
          Ne(:,ki+4)= varphi(k_md)*v_md(:,1,k_md)
          Ne(:,ki+5)=-varphi(k_md)*v_md(:,2,k_md)
        end do
        ! Load shape functions
#       define etype dtype
#       define delta 0.0d0
#       define xi xip
#       include <phi_2d.rc>
#       undef etype
#       undef delta
#       undef xi
        ! Build load shape function matrix Nedge
        Nedge=0.d0
        do k_dn=1,n_dn
          ki=(k_dn-1)*3
          Nedge(1,ki+1)=phi(k_dn)
          Nedge(2,ki+2)=phi(k_dn)
          Nedge(3,ki+3)=phi(k_dn)
        end do
        ! jacobians * weights
        jw=jg*w(1)*w(2)
        ! Add
        Q=Q+matmul(transpose(Ne),Nedge)*jw
      end do
    end do
  end subroutine fbem_fem_degshell_Q_edge

  !! Calculate the local load to global load transformation matrix Ld in the mid-plane (xi3=0)
  subroutine fbem_fem_degshell_Ld(etype,x_midnodes,t1ref,tol,Ld)
    implicit none
    ! I/O
    integer           :: etype                                           !! Type of element (displacements interpolation): tri3, tri6, quad4, quad8, quad9.
    real(kind=real64) :: x_midnodes(3,fbem_n_nodes(etype))               !! Position vectors of the mid-plane nodes.
    real(kind=real64) :: t1ref(3)                                        !! Reference vector to define the t1-n plane, if null, then e1, e2 and e3 are used as t1ref
    real(kind=real64) :: tol                                             !! Geometric tolerance
    real(kind=real64) :: Ld(5*fbem_n_nodes(etype),5*fbem_n_nodes(etype)) !! Transformation matrix Ld
    ! Local
    integer           :: n_midnodes                           ! Number of mid-nodes
    integer           :: kn, kmidnode                         ! Counters of mid-nodes
    real(kind=real64) :: xi(2)                                ! Curvilinear coordinates
    real(kind=real64) :: aux(10)                              ! Auxiliary variable needed for shape_functions module resources
    real(kind=real64) :: phi(fbem_n_nodes(etype))             ! phi shape functions
    real(kind=real64) :: dphidxi1(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_1
    real(kind=real64) :: dphidxi2(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_2
    real(kind=real64) :: T1(3), T2(3), N(3)                   ! Derivatives of position with respect to curvilinear coordinates and the normal vector to the mid-plane
    real(kind=real64) :: xi_element(2,fbem_n_nodes(etype))    ! xi coordinates of each node
    integer           :: ki                                   ! Counter
    !
    ! Initialization
    !
    ! Initialize load matrix at xi3=0 (mid-plane)
    Ld=0.d0
    ! Number of mid-nodes
    n_midnodes=fbem_n_nodes(etype)
    !
    ! Build Ld matrix
    !
    xi_element=fbem_xi1xi2(etype,0.d0)
    do kn=1,n_midnodes
      ! xi1,xi2 coordinates of the node kn
      xi=xi_element(:,kn)
      ! In-plane shape functions and their first derivatives with respect to xi_1, xi_2 at (xi_1,xi_2)
#     define delta 0.0d0
#     include <phi_and_dphidxik_2d.rc>
#     undef delta
      ! Calculate T1 and T2
      T1=0.d0
      T2=0.d0
      do kmidnode=1,n_midnodes
        T1=T1+dphidxi1(kmidnode)*x_midnodes(:,kmidnode)
        T2=T2+dphidxi2(kmidnode)*x_midnodes(:,kmidnode)
      end do
      ! Calculate N (normal vector) as T1 x T2 at (xi_1,xi_2,0)
      N(1)=T1(2)*T2(3)-T1(3)*T2(2)
      N(2)=T1(3)*T2(1)-T1(1)*T2(3)
      N(3)=T1(1)*T2(2)-T1(2)*T2(1)
      ! Unit normal
      n=N/sqrt(dot_product(N,N))
      !
      ! Build the orthogonal tangents (t1 and t2) to the mid-plane
      !
      ! if |t1ref|!=0 (use t1ref)
      if (sqrt(dot_product(t1ref,t1ref)).gt.tol) then
        ! t2 = n x t1ref
        t2(1)=n(2)*t1ref(3)-n(3)*t1ref(2)
        t2(2)=n(3)*t1ref(1)-n(1)*t1ref(3)
        t2(3)=n(1)*t1ref(2)-n(2)*t1ref(1)
        ! Check if parallel to n
        if (sqrt(dot_product(t2,t2)).le.tol) then
          call fbem_error_message(error_unit,0,__FILE__,__LINE__,'a t1ref vector is parallel to the n vector of a node')
        end if
      ! if |t1ref|!=0 (use e1, e2 or e3)
      else
       ! e1 as reference vector
        t2(1) = 0.0d0
        t2(2) = n(3)
        t2(3) =-n(2)
        if (sqrt(dot_product(t2,t2)).le.tol) then
          ! e2 as reference vector
          t2(1) =-n(3)
          t2(2) = 0.0d0
          t2(3) = n(1)
          if (sqrt(dot_product(t2,t2)).le.tol) then
            ! e3 as reference vector
            t2(1) = n(2)
            t2(2) =-n(1)
            t2(3) = 0.0d0
            if (sqrt(dot_product(t2,t2)).le.tol) then
              call fbem_error_message(error_unit,0,__FILE__,__LINE__,'Fatal error. Check subroutine fbem_fem_degshell_Ld().')
            end if
          end if
        end if
      end if
      ! Ensure |t2|=1
      t2=t2/sqrt(dot_product(t2,t2))
      ! Build t1 = t2 x n
      t1(1) = t2(2)*n(3)-t2(3)*n(2)
      t1(2) = t2(3)*n(1)-t2(1)*n(3)
      t1(3) = t2(1)*n(2)-t2(2)*n(1)
      ! Ensure |t1|=1
      t1=t1/sqrt(dot_product(t1,t1))
      ! Copy to Ld
      ki=(kn-1)*5+1
      Ld(ki:ki+2,ki  )=t1
      Ld(ki:ki+2,ki+1)=t2
      Ld(ki:ki+2,ki+2)=n
      Ld(ki+3,ki+3)=1.d0
      Ld(ki+4,ki+4)=1.d0
    end do
  end subroutine fbem_fem_degshell_Ld






  !! Calculate the local load to global load transformation matrix Ld in the mid-plane (xi3=0)
  subroutine fbem_fem_degshell_L_load(etype,x_midnodes,t1ref,tol,Ld)
    implicit none
    ! I/O
    integer           :: etype                                           !! Type of element (displacements interpolation): tri3, tri6, quad4, quad8, quad9.
    real(kind=real64) :: x_midnodes(3,fbem_n_nodes(etype))               !! Position vectors of the mid-plane nodes.
    real(kind=real64) :: t1ref(3)                                        !! Reference vector to define the t1-n plane, if null, then e1, e2 and e3 are used as t1ref
    real(kind=real64) :: tol                                             !! Geometric tolerance
    real(kind=real64) :: Ld(3*fbem_n_nodes(etype),3*fbem_n_nodes(etype)) !! Transformation matrix Ld
    ! Local
    integer           :: n_midnodes                           ! Number of mid-nodes
    integer           :: kn, kmidnode                         ! Counters of mid-nodes
    real(kind=real64) :: xi(2)                                ! Curvilinear coordinates
    real(kind=real64) :: aux(10)                              ! Auxiliary variable needed for shape_functions module resources
    real(kind=real64) :: phi(fbem_n_nodes(etype))             ! phi shape functions
    real(kind=real64) :: dphidxi1(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_1
    real(kind=real64) :: dphidxi2(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_2
    real(kind=real64) :: T1(3), T2(3), N(3)                   ! Derivatives of position with respect to curvilinear coordinates and the normal vector to the mid-plane
    real(kind=real64) :: xi_element(2,fbem_n_nodes(etype))    ! xi coordinates of each node
    integer           :: ki                                   ! Counter
    !
    ! Initialization
    !
    ! Initialize load matrix at xi3=0 (mid-plane)
    Ld=0
    ! Number of mid-nodes
    n_midnodes=fbem_n_nodes(etype)
    !
    ! Build Ld matrix
    !
    xi_element=fbem_xi1xi2(etype,0.d0)
    do kn=1,n_midnodes
      ! xi1,xi2 coordinates of the node kn
      xi=xi_element(:,kn)
      ! In-plane shape functions and their first derivatives with respect to xi_1, xi_2 at (xi_1,xi_2)
#     define delta 0.0d0
#     include <phi_and_dphidxik_2d.rc>
#     undef delta
      ! Calculate T1 and T2
      T1=0.d0
      T2=0.d0
      do kmidnode=1,n_midnodes
        T1=T1+dphidxi1(kmidnode)*x_midnodes(:,kmidnode)
        T2=T2+dphidxi2(kmidnode)*x_midnodes(:,kmidnode)
      end do
      ! Calculate N (normal vector) as T1 x T2 at (xi_1,xi_2,0)
      N(1)=T1(2)*T2(3)-T1(3)*T2(2)
      N(2)=T1(3)*T2(1)-T1(1)*T2(3)
      N(3)=T1(1)*T2(2)-T1(2)*T2(1)
      ! Unit normal
      n=N/sqrt(dot_product(N,N))
      !
      ! Build the orthogonal tangents (t1 and t2) to the mid-plane
      !
      ! if |t1ref|!=0 (use t1ref)
      if (sqrt(dot_product(t1ref,t1ref)).gt.tol) then
        ! t2 = n x t1ref
        t2(1)=n(2)*t1ref(3)-n(3)*t1ref(2)
        t2(2)=n(3)*t1ref(1)-n(1)*t1ref(3)
        t2(3)=n(1)*t1ref(2)-n(2)*t1ref(1)
        ! Check if parallel to n
        if (sqrt(dot_product(t2,t2)).le.tol) then
          call fbem_error_message(error_unit,0,__FILE__,__LINE__,'a t1ref vector is parallel to the n vector of a node')
        end if
      ! if |t1ref|!=0 (use e1, e2 or e3)
      else
       ! e1 as reference vector
        t2(1) = 0.0d0
        t2(2) = n(3)
        t2(3) =-n(2)
        if (sqrt(dot_product(t2,t2)).le.tol) then
          ! e2 as reference vector
          t2(1) =-n(3)
          t2(2) = 0.0d0
          t2(3) = n(1)
          if (sqrt(dot_product(t2,t2)).le.tol) then
            ! e3 as reference vector
            t2(1) = n(2)
            t2(2) =-n(1)
            t2(3) = 0.0d0
            if (sqrt(dot_product(t2,t2)).le.tol) then
              call fbem_error_message(error_unit,0,__FILE__,__LINE__,'Fatal error. Check subroutine fbem_fem_degshell_Ld().')
            end if
          end if
        end if
      end if
      ! Ensure |t2|=1
      t2=t2/sqrt(dot_product(t2,t2))
      ! Build t1 = t2 x n
      t1(1) = t2(2)*n(3)-t2(3)*n(2)
      t1(2) = t2(3)*n(1)-t2(1)*n(3)
      t1(3) = t2(1)*n(2)-t2(2)*n(1)
      ! Ensure |t1|=1
      t1=t1/sqrt(dot_product(t1,t1))
      ! Copy to Ld
      ki=(kn-1)*3+1
      Ld(ki:ki+2,ki  )=t1
      Ld(ki:ki+2,ki+1)=t2
      Ld(ki:ki+2,ki+2)=n
    end do
  end subroutine fbem_fem_degshell_L_load







  ! Stress resultants extrapolated from Gauss points. Remember Fsigma must be later multiplied by E (Young modulus)
  subroutine fbem_fem_degshell_stress_resultants(etype,x_midnodes,v_midnode,t_midnodes,x1ref,nu,kappa,setype,sedelta,Fsigma)
    implicit none
    ! I/O
    integer           :: etype                              !! Type of element (displacements interpolation): tri3, tri6, quad4, quad8, quad9.
    real(kind=real64) :: x_midnodes(3,fbem_n_nodes(etype))  !! Position vectors of the mid-plane nodes.
    real(kind=real64) :: v_midnode(3,3,fbem_n_nodes(etype)) !! Local axes for each mid-node for the rotation degrees of freedom.
    real(kind=real64) :: t_midnodes(3,fbem_n_nodes(etype))  !! Thickness of each mid-node in each direction (only v_3 makes sense).
    real(kind=real64) :: x1ref(3)                           !! Reference vector for x' direction (if 0, t1 is taken as ep1)
    real(kind=real64) :: nu                                 !! Poisson's ratio
    real(kind=real64) :: kappa(3)                           !! Shear correction factors: kx', ky',-
    integer           :: setype                             !! Stress interpolation: type of interpolation
    real(kind=real64) :: sedelta                            !! Stress interpolation: delta of type of interpolation
    real(kind=real64), allocatable :: Fsigma(:,:,:)         !! Stress resultants matrix at interpolation points (without multiplying by E). Criterio signos Oñate.fig 8.9
    ! Local
    integer           :: ksp
    real(kind=real64), allocatable :: sephi(:)                ! Stress interpolation: shape function values
    real(kind=real64) :: xi_sp(2)
    integer           :: ngpth                                ! Number of Gauss-Legendre integration points for thickness coordinate (xi3)
    integer           :: n_midnodes                           ! Number of mid-nodes
    integer           :: kmidnode                             ! Counter of mid-nodes
    integer           :: kxi1, kxi2, kxi3, kxit               ! Integration points counters
    real(kind=real64) :: xi1, xi2, xi3, xi(2), w1, w2, w3, wt ! Curvilinear coordinates and quadrature weights
    real(kind=real64) :: aux(10)                              ! Auxiliary variable needed for shape_functions module resources
    real(kind=real64) :: phi(fbem_n_nodes(etype))             ! phi shape functions
    real(kind=real64) :: dphidxi1(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_1
    real(kind=real64) :: dphidxi2(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_2
    real(kind=real64) :: dphidxi3(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_3
    real(kind=real64) :: varphi(fbem_n_nodes(etype))          ! varphi shape functions
    real(kind=real64) :: dvarphidxi1(fbem_n_nodes(etype))     ! varphi shape functions derivatives with respect to xi_1
    real(kind=real64) :: dvarphidxi2(fbem_n_nodes(etype))     ! varphi shape functions derivatives with respect to xi_2
    real(kind=real64) :: dvarphidxi3(fbem_n_nodes(etype))     ! varphi shape functions derivatives with respect to xi_3
    real(kind=real64) :: t3_midnodes(fbem_n_nodes(etype))
    real(kind=real64) :: J(3,3), H(3,3), detJ                 ! Jacobian matrix, its inverse and the jacobian determinant
    real(kind=real64) :: jw, zp, r(3)                         ! det(J) * weights
    real(kind=real64) :: T1(3), T2(3), N(3)                   ! Derivatives of position with respect to curvilinear coordinates and the normal vector to the mid-plane
    real(kind=real64) :: ep1(3), ep2(3), ep3(3)               ! Local ortogonal axes
    real(kind=real64) :: E(5,6)                               ! E matrix
    real(kind=real64) :: G(6,9)                               ! G matrix
    real(kind=real64) :: M(9,5)                               ! M matrix (shape function matrices derivatives)
    real(kind=real64) :: Bp(5,5,fbem_n_nodes(etype))          ! B' matrix
    real(kind=real64) :: B(6,5,fbem_n_nodes(etype))           ! B matrix
    real(kind=real64) :: Dp(5,5)                              ! D' constitutive matrix (local coordinates)
    integer           :: ki, kis, kie, kj, kjs, kje           ! Counters and nodal DOF limits
    !
    ! Initialization
    !
    ! Number of integration points along thickness direction
    ngpth=2
    ! Number of mid-nodes
    n_midnodes=fbem_n_nodes(etype)
    t3_midnodes=t_midnodes(3,:)
    ! Local constitutive matrix D'
    Dp=0.d0
    Dp(1,1)=1.d0
    Dp(1,2)=nu
    Dp(2,1)=nu
    Dp(2,2)=1.d0
    Dp(3,3)=0.5d0*(1.d0-nu)
    Dp(4,4)=kappa(1)*0.5d0*(1.d0-nu)
    Dp(5,5)=kappa(2)*0.5d0*(1.d0-nu)
    Dp=1.d0/(1.d0-nu**2)*Dp
    ! Select the stress interpolation scheme
    select case (etype)
      case (fbem_tri3)
        setype=fbem_tri1
        sedelta=0.d0
      case (fbem_tri6)
        setype=fbem_tri4
        sedelta=0.6d0
      case (fbem_quad4)
        setype=fbem_quad1
        sedelta=0.d0
      case (fbem_quad8,fbem_quad9)
        setype=fbem_quad4
        sedelta=0.42264973d0
      case default
        call fbem_error_message(error_unit,0,__FILE__,__LINE__,'etype={tri3,tri6,quad4,quad8,quad9}')
    end select
    ! Sin interpolacion desde puntos de Gauss
    !setype=etype
    !sedelta=0
    ! Local stress resultants matrix at interpolation points
    allocate(Fsigma(8,5*n_midnodes,fbem_n_nodes(setype)))
    Fsigma=0.
    !
    ! Loops through sampling points
    !
    do ksp=1,fbem_n_nodes(setype)
      ! Sampling points coordinates
#     define node ksp
#     define etype setype
#     define delta sedelta
#     define xi xi_sp
#     include <xi_2d_at_node.rc>
#     undef node
#     undef etype
#     undef delta
#     undef xi
      xi1=xi_sp(1)
      xi2=xi_sp(2)
      !
      ! Integrate along xi3 at mid-surface point (xi1,xi2)
      !
      do kxi3=1,ngpth
        ! xi_3 and w_3
        xi3=gl11_xi(kxi3,ngpth)
        w3=gl11_w(kxi3,ngpth)
        ! In-plane shape functions and their first derivatives with respect to xi_1, xi_2 and xi_3 at (xi_1,xi_2,xi_3)
        xi(1)=xi1
        xi(2)=xi2
#       define delta 0.0d0
#       include <phi_and_dphidxik_2d.rc>
#       undef delta
        dphidxi3=0.d0
        ! Thickness shape function and its derivative with respect to xi_1, xi_2 and xi_3 at (xi_1,xi_2,xi_3)
        varphi=phi*0.5d0*xi3*t3_midnodes
        dvarphidxi1=dphidxi1*0.5d0*xi3*t3_midnodes
        dvarphidxi2=dphidxi2*0.5d0*xi3*t3_midnodes
        dvarphidxi3=phi*0.5d0*t3_midnodes
        ! Calculate position vector x, and Jacobian matrix at (xi_1,xi_2,xi_3)
        J=0.d0
        do kmidnode=1,n_midnodes
          J(1,:)=J(1,:)+dphidxi1(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi1(kmidnode)*v_midnode(:,3,kmidnode)
          J(2,:)=J(2,:)+dphidxi2(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi2(kmidnode)*v_midnode(:,3,kmidnode)
          J(3,:)=J(3,:)+dphidxi3(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi3(kmidnode)*v_midnode(:,3,kmidnode)
        end do
        call fbem_invert_3x3_matrix(J,H,detJ)
        ! Calculate local orthogonal system of coordinates (ep_1,ep_2,ep_3) at (xi_1,xi_2,xi_3)
        ! Tangents T1 and T2
        T1=J(1,:)
        T2=J(2,:)
        ! Calculate N (normal vector) as T1 x T2 at (xi_1,xi_2,0)
        N(1)=T1(2)*T2(3)-T1(3)*T2(2)
        N(2)=T1(3)*T2(1)-T1(1)*T2(3)
        N(3)=T1(1)*T2(2)-T1(2)*T2(1)
        ! Local coordinates system
        call fbem_fem_degshell_stress_resultants_ep(N,T1,x1ref,ep1,ep2,ep3)
        ! Global (x) to local (x') tensor transformation matrix
        E=0.d0
        E(1,1:3)=ep1**2
        E(1,4)=ep1(1)*ep1(2)
        E(1,5)=ep1(2)*ep1(3)
        E(1,6)=ep1(1)*ep1(3)
        E(2,1:3)=ep2**2
        E(2,4)=ep2(1)*ep2(2)
        E(2,5)=ep2(2)*ep2(3)
        E(2,6)=ep2(1)*ep2(3)
        E(3,1)=ep1(1)*ep2(1)
        E(3,2)=ep1(2)*ep2(2)
        E(3,3)=ep1(3)*ep2(3)
        E(4,1)=ep2(1)*ep3(1)
        E(4,2)=ep2(2)*ep3(2)
        E(4,3)=ep2(3)*ep3(3)
        E(5,1)=ep1(1)*ep3(1)
        E(5,2)=ep1(2)*ep3(2)
        E(5,3)=ep1(3)*ep3(3)
        E(3:5,1:3)=2.d0*E(3:5,1:3)
        E(3,4)=ep1(1)*ep2(2)+ep1(2)*ep2(1)
        E(3,5)=ep1(2)*ep2(3)+ep1(3)*ep2(2)
        E(3,6)=ep1(1)*ep2(3)+ep1(3)*ep2(1)
        E(4,4)=ep2(1)*ep3(2)+ep2(2)*ep3(1)
        E(4,5)=ep2(2)*ep3(3)+ep2(3)*ep3(2)
        E(4,6)=ep2(1)*ep3(3)+ep2(3)*ep3(1)
        E(5,4)=ep1(1)*ep3(2)+ep1(2)*ep3(1)
        E(5,5)=ep1(2)*ep3(3)+ep1(3)*ep3(2)
        E(5,6)=ep1(1)*ep3(3)+ep1(3)*ep3(1)
        ! Derivative transformation matrix for curvilinear to global cartesian tensor transformation
        G=0.d0
        G(1,1)=H(1,1)
        G(2,2)=H(2,1)
        G(3,3)=H(3,1)
        G(4,1)=H(2,1)
        G(4,2)=H(1,1)
        G(5,2)=H(3,1)
        G(5,3)=H(2,1)
        G(6,1)=H(3,1)
        G(6,3)=H(1,1)
        G(1,4)=H(1,2)
        G(2,5)=H(2,2)
        G(3,6)=H(3,2)
        G(4,4)=H(2,2)
        G(4,5)=H(1,2)
        G(5,5)=H(3,2)
        G(5,6)=H(2,2)
        G(6,4)=H(3,2)
        G(6,6)=H(1,2)
        G(1,7)=H(1,3)
        G(2,8)=H(2,3)
        G(3,9)=H(3,3)
        G(4,7)=H(2,3)
        G(4,8)=H(1,3)
        G(5,8)=H(3,3)
        G(5,9)=H(2,3)
        G(6,7)=H(3,3)
        G(6,9)=H(1,3)
        ! Build matrix B for all nodes
        do kmidnode=1,n_midnodes
          ! Matrix of derivatives of shape functions matrices with respect to xi1, xi2 and xi3
          M=0.d0
          M(  1,1)= dphidxi1(kmidnode)
          M(  2,2)= dphidxi1(kmidnode)
          M(  3,3)= dphidxi1(kmidnode)
          M(1:3,4)= dvarphidxi1(kmidnode)*v_midnode(:,1,kmidnode)
          M(1:3,5)=-dvarphidxi1(kmidnode)*v_midnode(:,2,kmidnode)
          M(  4,1)= dphidxi2(kmidnode)
          M(  5,2)= dphidxi2(kmidnode)
          M(  6,3)= dphidxi2(kmidnode)
          M(4:6,4)= dvarphidxi2(kmidnode)*v_midnode(:,1,kmidnode)
          M(4:6,5)=-dvarphidxi2(kmidnode)*v_midnode(:,2,kmidnode)
          M(  7,1)= dphidxi3(kmidnode)
          M(  8,2)= dphidxi3(kmidnode)
          M(  9,3)= dphidxi3(kmidnode)
          M(7:9,4)= dvarphidxi3(kmidnode)*v_midnode(:,1,kmidnode)
          M(7:9,5)=-dvarphidxi3(kmidnode)*v_midnode(:,2,kmidnode)
          ! B matrix for kmidnode
          B(:,:,kmidnode)=matmul(G,M)
          ! B' matrix for kmidnode
          Bp(:,:,kmidnode)=matmul(E,B(:,:,kmidnode))
        end do
        ! |J(3,:)| * weight
        jw=sqrt(dot_product(J(3,:),J(3,:)))*w3
        ! Distance z'
        ! Distance vector between (xi1,xi2,0)->(xi1,xi2,xi3)
        r=0
        do kmidnode=1,n_midnodes
          r=r+varphi(kmidnode)*v_midnode(:,3,kmidnode)
        end do
        ! Projection
        zp=dot_product(r,ep3)
        ! Build the stress resultants matrix at (xi1,xi2)
        do kj=1,n_midnodes
          kjs=(kj-1)*5+1
          kje=kjs+4
          Fsigma(1:3,kjs:kje,ksp)=Fsigma(1:3,kjs:kje,ksp)+matmul(Dp(1:3,:),Bp(:,:,kj))*jw             ! In-plane membrane forces: Nx', Ny' and Nx'y'
          Fsigma(4:6,kjs:kje,ksp)=Fsigma(4:6,kjs:kje,ksp)-matmul(Dp(1:3,:),Bp(:,:,kj))*zp*jw          ! Bending moments: Mx', My' and Mx'y'
          Fsigma(  7,kjs:kje,ksp)=Fsigma(  7,kjs:kje,ksp)+matmul(Dp(  5,:),Bp(:,:,kj))*jw             ! Out-plane shear forces: Vx'
          Fsigma(  8,kjs:kje,ksp)=Fsigma(  8,kjs:kje,ksp)+matmul(Dp(  4,:),Bp(:,:,kj))*jw             ! Out-plane shear forces: Vy'
        end do
      end do ! Integrate along xi3 at mid-surface point (xi1,xi2)
    end do ! Loop through interpolation points
  end subroutine fbem_fem_degshell_stress_resultants

  !! Build the orthonormal basis e1', e2', e3' for stress resultant calculation from reference vector e1'ref
  subroutine fbem_fem_degshell_stress_resultants_ep(N,T1,ep1ref,ep1,ep2,ep3)
    implicit none
    real(kind=real64) :: N(3), T1(3)
    real(kind=real64) :: ep1ref(3)
    real(kind=real64) :: ep1(3), ep2(3), ep3(3)
    ! ep_3 = n
    ep3=N/sqrt(dot_product(N,N))
    if (sqrt(dot_product(ep1ref,ep1ref)).le.1.d-14) then
      ! ep_1 = t1
      ep1=T1/sqrt(dot_product(T1,T1))
      ! ep_2 = ep_3 x ep_1
      ep2(1)=ep3(2)*ep1(3)-ep3(3)*ep1(2)
      ep2(2)=ep3(3)*ep1(1)-ep3(1)*ep1(3)
      ep2(3)=ep3(1)*ep1(2)-ep3(2)*ep1(1)
    else
      ! ep_2 = (ep_3 x ep1ref) / | ep_3 x ep1ref |
      ep2=fbem_cross_product(ep3,ep1ref)
      ep2=ep2/sqrt(dot_product(ep2,ep2))
      ! ep_1 = ep_2 x ep_3
      ep1(1)=ep2(2)*ep3(3)-ep2(3)*ep3(2)
      ep1(2)=ep2(3)*ep3(1)-ep2(1)*ep3(3)
      ep1(3)=ep2(1)*ep3(2)-ep2(2)*ep3(1)
    end if
  end subroutine fbem_fem_degshell_stress_resultants_ep

  ! Stress tensor at a given point extrapolated from Gauss points. Ssigma must be later multiplied by Young's modulus E and element
  ! displacement vector.
  subroutine fbem_fem_degshell_stress_tensor(etype,x_midnodes,v_midnode,t_midnodes,nu,kappa,xi_i,Ssigma_i)
    implicit none
    ! I/O
    integer           :: etype                              !! Type of element (displacements interpolation): tri3, tri6, quad4, quad8, quad9.
    real(kind=real64) :: x_midnodes(3,fbem_n_nodes(etype))  !! Position vectors of the mid-plane nodes.
    real(kind=real64) :: v_midnode(3,3,fbem_n_nodes(etype)) !! Local axes for each mid-node for the rotation degrees of freedom.
    real(kind=real64) :: t_midnodes(fbem_n_nodes(etype))    !! Thickness of each mid-node in the v_3 direction.
    real(kind=real64) :: nu                                 !! Poisson's ratio
    real(kind=real64) :: kappa(3)                           !! Shear correction factors: kx', ky',-
    real(kind=real64) :: xi_i(3)                            !! Local coordinate xi_i
    real(kind=real64) :: Ssigma_i(6,5*fbem_n_nodes(etype))  !! Stress tensor at xi_i (without E)
    ! Local
    real(kind=real64), allocatable :: Ssigma(:,:,:,:)         ! Stress tensor at interpolation points (without E)
    integer           :: setype                               ! Stress interpolation: type of interpolation
    real(kind=real64) :: sedelta                              ! Stress interpolation: delta of type of interpolation
    integer           :: ksp                                  ! Sampling point counter
    real(kind=real64), allocatable :: sephi(:)                ! Stress interpolation: shape function values
    real(kind=real64) :: xi_sp(2)                             ! Local coordinate of the sampling point
    integer           :: ngpth                                ! Number of Gauss-Legendre integration points for thickness coordinate (xi3)
    integer           :: n_midnodes                           ! Number of mid-nodes
    integer           :: kmidnode                             ! Counter of mid-nodes
    integer           :: kxi1, kxi2, kxi3, kxit               ! Integration points counters
    real(kind=real64) :: xi1, xi2, xi3, xi(2), w1, w2, w3, wt ! Curvilinear coordinates and quadrature weights
    real(kind=real64) :: aux(10)                              ! Auxiliary variable needed for shape_functions module resources
    real(kind=real64) :: phi(fbem_n_nodes(etype))             ! phi shape functions
    real(kind=real64) :: dphidxi1(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_1
    real(kind=real64) :: dphidxi2(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_2
    real(kind=real64) :: dphidxi3(fbem_n_nodes(etype))        ! phi shape functions derivatives with respect to xi_3
    real(kind=real64) :: varphi(fbem_n_nodes(etype))          ! varphi shape functions
    real(kind=real64) :: dvarphidxi1(fbem_n_nodes(etype))     ! varphi shape functions derivatives with respect to xi_1
    real(kind=real64) :: dvarphidxi2(fbem_n_nodes(etype))     ! varphi shape functions derivatives with respect to xi_2
    real(kind=real64) :: dvarphidxi3(fbem_n_nodes(etype))     ! varphi shape functions derivatives with respect to xi_3
    real(kind=real64) :: J(3,3), H(3,3), detJ                 ! Jacobian matrix, its inverse and the jacobian determinant
    real(kind=real64) :: jw                                   ! det(J) * weights
    real(kind=real64) :: T1(3), T2(3), N(3)                   ! Derivatives of position with respect to curvilinear coordinates and the normal vector to the mid-plane
    real(kind=real64) :: ep1(3), ep2(3), ep3(3)               ! Local ortogonal axes
    real(kind=real64) :: E(5,6)                               ! E matrix
    real(kind=real64) :: G(6,9)                               ! G matrix
    real(kind=real64) :: M(9,5)                               ! M matrix (shape function matrices derivatives)
    real(kind=real64) :: Bp(5,5,fbem_n_nodes(etype))          ! B' matrix
    real(kind=real64) :: B(6,5,fbem_n_nodes(etype))           ! B matrix
    real(kind=real64) :: Dp(5,5)                              ! D' constitutive matrix (local coordinates)
    real(kind=real64) :: D(6,6)                               ! D constitutive matrix (global coordinates)
    integer           :: ki, kis, kie, kj, kjs, kje           ! Counters and nodal DOF limits
    !
    ! Initialization
    !
    ! Number of mid-nodes
    n_midnodes=fbem_n_nodes(etype)
    ! Local constitutive matrix D'
    Dp=0.d0
    Dp(1,1)=1.d0
    Dp(1,2)=nu
    Dp(2,1)=nu
    Dp(2,2)=1.d0
    Dp(3,3)=0.5d0*(1.d0-nu)
    Dp(4,4)=kappa(1)*0.5d0*(1.d0-nu)
    Dp(5,5)=kappa(2)*0.5d0*(1.d0-nu)
    Dp=1.d0/(1.d0-nu**2)*Dp
    ! Select the stress interpolation scheme
    select case (etype)
      case (fbem_tri3)
        setype=fbem_tri1
        sedelta=0.d0
      case (fbem_tri6)
        setype=fbem_tri4
        sedelta=0.6d0
      case (fbem_quad4)
        setype=fbem_quad1
        sedelta=0.d0
      case (fbem_quad8,fbem_quad9)
        setype=fbem_quad4
        sedelta=0.42264973d0
      case default
        call fbem_error_message(error_unit,0,__FILE__,__LINE__,'etype={tri3,tri6,quad4,quad8,quad9}')
    end select
    ! Sin interpolacion desde puntos de Gauss
    !setype=etype
    !sedelta=0
    ! Local stress resultants matrix at interpolation points
    allocate(Ssigma(6,5*n_midnodes,fbem_n_nodes(setype),2))
    !
    ! Loop through sampling points (in-plane coordinates)
    !
    do ksp=1,fbem_n_nodes(setype)
      ! Sampling points coordinates
#     define node ksp
#     define etype setype
#     define delta sedelta
#     define xi xi_sp
#     include <xi_2d_at_node.rc>
#     undef node
#     undef etype
#     undef delta
#     undef xi
      xi1=xi_sp(1)
      xi2=xi_sp(2)
      !
      ! Loop through sampling points (out-of-plane coordinates)
      !
      do kxi3=1,2
        ! xi_3 and w_3
        xi3=gl11_xi(kxi3,2)
        ! In-plane shape functions and their first derivatives with respect to xi_1, xi_2 and xi_3 at (xi_1,xi_2,xi_3)
        xi(1)=xi1
        xi(2)=xi2
#       define delta 0.0d0
#       include <phi_and_dphidxik_2d.rc>
#       undef delta
        dphidxi3=0.d0
        ! Thickness shape function and its derivative with respect to xi_1, xi_2 and xi_3 at (xi_1,xi_2,xi_3)
        varphi=phi*0.5d0*xi3*t_midnodes
        dvarphidxi1=dphidxi1*0.5d0*xi3*t_midnodes
        dvarphidxi2=dphidxi2*0.5d0*xi3*t_midnodes
        dvarphidxi3=phi*0.5d0*t_midnodes
        ! Calculate position vector x, and Jacobian matrix at (xi_1,xi_2,xi_3)
        J=0.d0
        do kmidnode=1,n_midnodes
          J(1,:)=J(1,:)+dphidxi1(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi1(kmidnode)*v_midnode(:,3,kmidnode)
          J(2,:)=J(2,:)+dphidxi2(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi2(kmidnode)*v_midnode(:,3,kmidnode)
          J(3,:)=J(3,:)+dphidxi3(kmidnode)*x_midnodes(:,kmidnode)+dvarphidxi3(kmidnode)*v_midnode(:,3,kmidnode)
        end do
        call fbem_invert_3x3_matrix(J,H,detJ)
        ! Calculate local orthogonal system of coordinates (ep_1,ep_2,ep_3) at (xi_1,xi_2,xi_3)
        ! Tangents T1 and T2
        T1=J(1,:)
        T2=J(2,:)
        ! Calculate N (normal vector) as T1 x T2 at (xi_1,xi_2,0)
        N(1)=T1(2)*T2(3)-T1(3)*T2(2)
        N(2)=T1(3)*T2(1)-T1(1)*T2(3)
        N(3)=T1(1)*T2(2)-T1(2)*T2(1)
        ! ep_3 = n
        ep3=N/sqrt(dot_product(N,N))
        ! ep_1 = t1
        ep1=T1/sqrt(dot_product(T1,T1))
        ! ep_2 = ep_3 x ep_1
        ep2(1)=ep3(2)*ep1(3)-ep3(3)*ep1(2)
        ep2(2)=ep3(3)*ep1(1)-ep3(1)*ep1(3)
        ep2(3)=ep3(1)*ep1(2)-ep3(2)*ep1(1)
        ! Global (x) to local (x') tensor transformation matrix
        E=0.d0
        E(1,1:3)=ep1**2
        E(1,4)=ep1(1)*ep1(2)
        E(1,5)=ep1(2)*ep1(3)
        E(1,6)=ep1(1)*ep1(3)
        E(2,1:3)=ep2**2
        E(2,4)=ep2(1)*ep2(2)
        E(2,5)=ep2(2)*ep2(3)
        E(2,6)=ep2(1)*ep2(3)
        E(3,1)=ep1(1)*ep2(1)
        E(3,2)=ep1(2)*ep2(2)
        E(3,3)=ep1(3)*ep2(3)
        E(4,1)=ep2(1)*ep3(1)
        E(4,2)=ep2(2)*ep3(2)
        E(4,3)=ep2(3)*ep3(3)
        E(5,1)=ep1(1)*ep3(1)
        E(5,2)=ep1(2)*ep3(2)
        E(5,3)=ep1(3)*ep3(3)
        E(3:5,1:3)=2.d0*E(3:5,1:3)
        E(3,4)=ep1(1)*ep2(2)+ep1(2)*ep2(1)
        E(3,5)=ep1(2)*ep2(3)+ep1(3)*ep2(2)
        E(3,6)=ep1(1)*ep2(3)+ep1(3)*ep2(1)
        E(4,4)=ep2(1)*ep3(2)+ep2(2)*ep3(1)
        E(4,5)=ep2(2)*ep3(3)+ep2(3)*ep3(2)
        E(4,6)=ep2(1)*ep3(3)+ep2(3)*ep3(1)
        E(5,4)=ep1(1)*ep3(2)+ep1(2)*ep3(1)
        E(5,5)=ep1(2)*ep3(3)+ep1(3)*ep3(2)
        E(5,6)=ep1(1)*ep3(3)+ep1(3)*ep3(1)
        ! Derivative transformation matrix for curvilinear to global cartesian tensor transformation
        G=0.d0
        G(1,1)=H(1,1)
        G(2,2)=H(2,1)
        G(3,3)=H(3,1)
        G(4,1)=H(2,1)
        G(4,2)=H(1,1)
        G(5,2)=H(3,1)
        G(5,3)=H(2,1)
        G(6,1)=H(3,1)
        G(6,3)=H(1,1)
        G(1,4)=H(1,2)
        G(2,5)=H(2,2)
        G(3,6)=H(3,2)
        G(4,4)=H(2,2)
        G(4,5)=H(1,2)
        G(5,5)=H(3,2)
        G(5,6)=H(2,2)
        G(6,4)=H(3,2)
        G(6,6)=H(1,2)
        G(1,7)=H(1,3)
        G(2,8)=H(2,3)
        G(3,9)=H(3,3)
        G(4,7)=H(2,3)
        G(4,8)=H(1,3)
        G(5,8)=H(3,3)
        G(5,9)=H(2,3)
        G(6,7)=H(3,3)
        G(6,9)=H(1,3)
        ! Build matrix B for all nodes
        do kmidnode=1,n_midnodes
          ! Matrix of derivatives of shape functions matrices with respect to xi1, xi2 and xi3
          M=0.d0
          M(  1,1)= dphidxi1(kmidnode)
          M(  2,2)= dphidxi1(kmidnode)
          M(  3,3)= dphidxi1(kmidnode)
          M(1:3,4)= dvarphidxi1(kmidnode)*v_midnode(:,1,kmidnode)
          M(1:3,5)=-dvarphidxi1(kmidnode)*v_midnode(:,2,kmidnode)
          M(  4,1)= dphidxi2(kmidnode)
          M(  5,2)= dphidxi2(kmidnode)
          M(  6,3)= dphidxi2(kmidnode)
          M(4:6,4)= dvarphidxi2(kmidnode)*v_midnode(:,1,kmidnode)
          M(4:6,5)=-dvarphidxi2(kmidnode)*v_midnode(:,2,kmidnode)
          M(  7,1)= dphidxi3(kmidnode)
          M(  8,2)= dphidxi3(kmidnode)
          M(  9,3)= dphidxi3(kmidnode)
          M(7:9,4)= dvarphidxi3(kmidnode)*v_midnode(:,1,kmidnode)
          M(7:9,5)=-dvarphidxi3(kmidnode)*v_midnode(:,2,kmidnode)
          ! B matrix for kmidnode
          B(:,:,kmidnode)=matmul(G,M)
        end do
        ! Constitutive matrix D (global coordinates)
        D=matmul(transpose(E),matmul(Dp,E))
        ! Build the stress resultants matrix at (xi2,xi2)
        do kj=1,n_midnodes
          kjs=(kj-1)*5+1
          kje=kjs+4
          Ssigma(:,kjs:kje,ksp,kxi3)=matmul(D(:,:),B(:,:,kj))
        end do
      end do ! Loop through sampling points (out-of-plane coordinates)
    end do ! Loop through sampling points (in-plane coordinates)
    ! Extrapolate to xi_i
    Ssigma_i=0
    ! Shape functions at xi_i
#   define xi xi_i
#   define etype setype
#   define delta sedelta
#   include <phi_2d.rc>
#   undef xi
#   undef etype
#   undef delta
    varphi(1)=0.5d0*(1.d0-xi_i(3)*sqrt(3.d0))
    varphi(2)=0.5d0*(1.d0+xi_i(3)*sqrt(3.d0))
    ! Calculate
    do ki=1,fbem_n_nodes(setype)
      Ssigma_i=Ssigma_i+phi(ki)*varphi(1)*Ssigma(:,:,ki,1)+phi(ki)*varphi(2)*Ssigma(:,:,ki,2)
    end do

  end subroutine fbem_fem_degshell_stress_tensor

end module fbem_fem_shells
