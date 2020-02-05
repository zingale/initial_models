!! generate an initial model for spherical geometry with a
!! uniform composition.  Here we take a base density and temperature
!! and use HSE and constant entropy to generate the model.

program init_1d

  use bl_types
  use bl_constants_module
  use bl_error_module
  use eos_module, only: eos, eos_init
  use eos_type_module, only: eos_t, eos_input_rt
  use network
  use fundamental_constants_module, only: Gconst

  implicit none

  integer :: i, n

  integer :: nx

  real (kind=dp_t), DIMENSION(nspec) :: xn_core

  real (kind=dp_t), allocatable :: xzn_hse(:), xznl(:), xznr(:)
  real (kind=dp_t), allocatable :: model_hse(:,:), M_enclosed(:)

  real (kind=dp_t) :: A, B, dAdT, dAdrho, dBdT, dBdrho

  ! define convenient indices for the scalars
  integer, parameter :: nvar = 3 + nspec
  integer, parameter :: idens = 1, &
                        itemp = 2, &
                        ipres = 3, &
                        ispec = 4

  real (kind=dp_t), parameter :: M_sun = 1.9891e33

  ! we'll get the composition indices from the network module
  integer, save :: ih1, ihe4
  real (kind=dp_t) :: hefrac

  integer :: narg
  character(len=128) :: params_file

  real (kind=dp_t), save :: xmin, xmax, dCoord

  real (kind=dp_t) :: dens_zone, temp_zone, pres_zone, entropy
  real (kind=dp_t) :: dpd, dpt, dsd, dst

  real (kind=dp_t) :: p_want, drho, dtemp, delx
  real (kind=dp_t), allocatable :: entropy_store(:), entropy_want(:)

  real (kind=dp_t) :: g_zone

  real (kind=dp_t), parameter :: TOL = 1.e-10

  integer, parameter :: MAX_ITER = 250

  integer :: iter, iter_mass

  logical :: converged_hse, mass_converged, fluff

  real (kind=dp_t) :: mass_star, mass_star_old

  real (kind=dp_t), dimension(nspec) :: xn

  real (kind=dp_t), save :: low_density_cutoff, temp_core, smallx, M_tot, temp_fluff
  real (kind=dp_t) :: rho_c, rho_c_old, drho_c

  logical :: isentropic

  character (len=256) :: outfile, prefix
  character (len=8) num

  real (kind=dp_t) :: max_hse_error, dpdr, rhog

  integer :: i_fluff

  type (eos_t) :: eos_state

  real, parameter :: TOL_MASS = 1.e-6_dp_t

  namelist /params/ nx, temp_core, &
                    low_density_cutoff, M_tot, temp_fluff, &
                    xmin, xmax, &
                    hefrac, prefix


  ! determine if we specified a runtime parameters file or use the default
  narg = command_argument_count()

  if (narg == 0) then
     params_file = "_params"
  else
     call get_command_argument(1, value = params_file)
  endif


  ! define the defaults parameters for this model
  nx = 1280

  smallx = 1.d-10

  xmin = 0_dp_t
  xmax = 5.d8

  low_density_cutoff =1.d-4
  temp_fluff = 1.d7

  hefrac = 0.3_dp_t

  prefix = "convective"


  ! check the namelist for any changed parameters
  open(unit=11, file=params_file, status="old", action="read")
  read(unit=11, nml=params)
  close(unit=11)


  ! initialize the EOS and network

  ! use_eos_coulomb comes in from extern_probin_module -- override
  ! here if desired
  call eos_init()
  call network_init()


  ! get the species indices
  ih1  = network_species_index("hydrogen-1")
  ihe4  = network_species_index("helium-4")


  if (ih1 < 0 .or. ihe4 < 0) then
     call bl_error("ERROR: species not defined")
  endif

  if (hefrac < 0.0_dp_t .or. hefrac > 1.0_dp_t) then
     call bl_error("ERROR: cfrac must be between 0 and 1")
  endif

  xn_core(:) = 0.0_dp_t
  xn_core(ihe4) = hefrac
  xn_core(ih1) = 1.0_dp_t - hefrac



!-----------------------------------------------------------------------------
! Create a 1-d uniform grid that is identical to the mesh that we are
! mapping onto, and then we want to force it into HSE on that mesh.
!-----------------------------------------------------------------------------

  ! allocate storage
  allocate(xzn_hse(nx))
  allocate(xznl(nx))
  allocate(xznr(nx))
  allocate(model_hse(nx,nvar))
  allocate(M_enclosed(nx))
  allocate(entropy_want(nx))
  allocate(entropy_store(nx))

  ! compute the coordinates of the new gridded function
  dCoord = (xmax - xmin) / dble(nx)

  do i = 1, nx
     xznl(i) = xmin + (dble(i) - 1.0_dp_t)*dCoord
     xznr(i) = xmin + (dble(i))*dCoord
     xzn_hse(i) = 0.5_dp_t*(xznl(i) + xznr(i))
  enddo

  ! We don't know what central density will give the desired total
  ! mass, so we need to iterate over central density

  ! we will do a secant iteration.  rho_c_old is the 'old' guess for
  ! the central density and rho_c is the current guess.  After 2
  ! loops, we can start estimating the density required to yield our
  ! desired mass
  rho_c_old = -1.0_dp_t
  rho_c     = 1.e3_dp_t     ! 1.e3 is a reasonable starting low mass star density

  mass_converged = .false.


  do iter_mass = 1, MAX_ITER

     print *, 'mass iter = ', iter_mass, rho_c, temp_core

     fluff = .false.

     ! call the EOS one more time to initialize the central conditions.
     eos_state%T     = temp_core
     eos_state%rho   = rho_c
     eos_state%xn(:) = xn_core(:)

     ! (t, rho) -> (p, s)
     call eos(eos_input_rt, eos_state)

     ! make the initial guess be completely uniform
     model_hse(:,idens) = eos_state%rho
     model_hse(:,itemp) = eos_state%T
     model_hse(:,ipres) = eos_state%p

     do i = 1, nspec
        model_hse(:,ispec-1+i) = eos_state%xn(i)
     enddo

     entropy_want(:) = eos_state%s

     ! keep track of the mass enclosed below the current zone
     M_enclosed(1) = FOUR3RD*M_PI*(xznr(1)**3 - xznl(1)**3)*model_hse(1,idens)


     !-----------------------------------------------------------------------------
     ! HSE + entropy solve
     !-----------------------------------------------------------------------------

     isentropic = .true.

     do i = 2, nx

        delx = xzn_hse(i) - xzn_hse(i-1)

        ! as the initial guess for the temperature and density, use the previous
        ! zone
        dens_zone = model_hse(i-1,idens)
        temp_zone = model_hse(i-1,itemp)
        xn(:) = model_hse(i,ispec:nvar)

        g_zone = -Gconst*M_enclosed(i-1)/(xznl(i)*xznl(i))

        !-----------------------------------------------------------------------
        ! iteration loop
        !-----------------------------------------------------------------------

        ! start off the Newton loop by saying that the zone has not converged
        converged_hse = .FALSE.

        if (.not. fluff) then

           do iter = 1, MAX_ITER

              if (isentropic) then

                 p_want = model_hse(i-1,ipres) + &
                      delx*0.5_dp_t*(dens_zone + model_hse(i-1,idens))*g_zone


                 ! now we have two functions to zero:
                 !   A = p_want - p(rho,T)
                 !   B = entropy_want - s(rho,T)
                 ! We use a two dimensional Taylor expansion and find the deltas
                 ! for both density and temperature

                 eos_state%T     = temp_zone
                 eos_state%rho   = dens_zone
                 eos_state%xn(:) = xn(:)

                 ! (t, rho) -> (p, s)
                 call eos(eos_input_rt, eos_state)

                 entropy = eos_state%s
                 pres_zone = eos_state%p

                 dpt = eos_state%dpdt
                 dpd = eos_state%dpdr
                 dst = eos_state%dsdt
                 dsd = eos_state%dsdr

                 A = p_want - pres_zone
                 B = entropy_want(i) - entropy

                 dAdT = -dpt
                 dAdrho = 0.5d0*delx*g_zone - dpd
                 dBdT = -dst
                 dBdrho = -dsd

                 dtemp = (B - (dBdrho/dAdrho)*A)/ &
                      ((dBdrho/dAdrho)*dAdT - dBdT)

                 drho = -(A + dAdT*dtemp)/dAdrho

                 dens_zone = max(0.9_dp_t*dens_zone, &
                      min(dens_zone + drho, 1.1_dp_t*dens_zone))

                 temp_zone = max(0.9_dp_t*temp_zone, &
                      min(temp_zone + dtemp, 1.1_dp_t*temp_zone))


                 ! check if the density falls below our minimum cut-off --
                 ! if so, floor it
                 if (dens_zone < low_density_cutoff) then

                    i_fluff = i

                    dens_zone = low_density_cutoff
                    temp_zone = temp_fluff
                    converged_hse = .TRUE.
                    fluff = .TRUE.
                    exit

                 endif


                 ! if (A < TOL .and. B < ETOL) then
                 if (abs(drho) < TOL*dens_zone .and. abs(dtemp) < TOL*temp_zone) then
                    converged_hse = .TRUE.
                    exit
                 endif

              else

                 ! do isothermal
                 p_want = model_hse(i-1,ipres) + &
                      delx*0.5*(dens_zone + model_hse(i-1,idens))*g_zone

                 temp_zone = model_hse(i-1,itemp)


                 eos_state%T     = temp_zone
                 eos_state%rho   = dens_zone
                 eos_state%xn(:) = xn(:)

                 ! (t, rho) -> (p, s)
                 call eos(eos_input_rt, eos_state)

                 entropy = eos_state%s
                 pres_zone = eos_state%p

                 dpd = eos_state%dpdr

                 drho = (p_want - pres_zone)/(dpd - 0.5*delx*g_zone)

                 dens_zone = max(0.9*dens_zone, &
                      min(dens_zone + drho, 1.1*dens_zone))

                 if (abs(drho) < TOL*dens_zone) then
                    converged_hse = .TRUE.
                    exit
                 endif


                 if (dens_zone < low_density_cutoff) then

                    i_fluff = i

                    dens_zone = low_density_cutoff
                    temp_zone = temp_fluff
                    converged_hse = .TRUE.
                    fluff = .TRUE.
                    exit

                 endif


              endif

           enddo

           if (.NOT. converged_hse) then

              print *, 'Error zone', i, ' did not converge in init_1d'
              print *, 'integrate up'
              print *, dens_zone, temp_zone
              print *, p_want
              print *, drho
              call bl_error('Error: HSE non-convergence')

           endif

           if (temp_zone < temp_fluff) then
              temp_zone = temp_fluff
              isentropic = .false.
           endif

        else
           dens_zone = low_density_cutoff
           temp_zone = temp_fluff
        endif


        ! call the EOS one more time for this zone and then go on to the next
        eos_state%T     = temp_zone
        eos_state%rho   = dens_zone
        eos_state%xn(:) = xn(:)

        ! (t, rho) -> (p, s)
        call eos(eos_input_rt, eos_state)

        pres_zone = eos_state%p

        ! update the thermodynamics in this zone
        model_hse(i,idens) = dens_zone
        model_hse(i,itemp) = temp_zone
        model_hse(i,ipres) = pres_zone

        !print *, i, dens_zone, temp_zone

        M_enclosed(i) = M_enclosed(i-1) + &
             FOUR3RD*M_PI*(xznr(i) - xznl(i))* &
             (xznr(i)**2 +xznl(i)*xznr(i) + xznl(i)**2)*model_hse(i,idens)

     enddo   ! loop over zones

     mass_star = M_enclosed(nx)

     print *, 'mass = ', M_enclosed(nx)/M_sun

     if (rho_c_old < 0.0_dp_t) then
        ! not enough iterations yet -- store the old central density and
        ! mass and pick a new value
        rho_c_old = rho_c
        mass_star_old = mass_star

        rho_c = 0.5*rho_c_old

     else
        ! have we converged
        if ( abs(mass_star - M_tot*M_sun)/(M_tot*M_sun) < TOL_MASS) then
           mass_converged = .true.
           exit
        endif

        ! do a secant iteration:
        ! M_tot = M(rho_c) + dM/drho |_rho_c x drho + ...        
        drho_c = (M_tot*M_sun - mass_star)/ &
             ( (mass_star  - mass_star_old)/(rho_c - rho_c_old) )

        rho_c_old = rho_c
        mass_star_old = mass_star

        rho_c = min(1.1_dp_t*rho_c_old, &
             max((rho_c + drho_c), 0.9_dp_t*rho_c_old))

     endif

  end do   ! end mass constraint loop

  if (.not. mass_converged) then
     print *, 'ERROR: star mass did not converge'
     call bl_error("ERROR: mass did not converge")
  endif


  write(num,'(i8)') nx
  outfile = trim(prefix) // ".hse." // trim(adjustl(num))



  open (unit=50, file=outfile, status="unknown")

  write (50,1001) "# npts = ", nx
  write (50,1001) "# num of variables = ", nvar
  write (50,1002) "# density"
  write (50,1002) "# temperature"
  write (50,1002) "# pressure"

  do n = 1, nspec
     write (50,1003) "# ", spec_names(n)
  enddo

1000 format (1x, 12(g26.16, 1x))
1001 format(a, i5)
1002 format(a)
1003 format(a,a)

  do i = 1, nx

     write (50,1000) xzn_hse(i), model_hse(i,idens), model_hse(i,itemp), model_hse(i,ipres), &
          (model_hse(i,ispec-1+n), n=1,nspec)

  enddo


  ! compute the maximum HSE error
  max_hse_error = -1.d30

  do i = 2, nx-1
     g_zone = -Gconst*M_enclosed(i-1)/xznr(i-1)**2
     dpdr = (model_hse(i,ipres) - model_hse(i-1,ipres))/delx
     rhog = HALF*(model_hse(i,idens) + model_hse(i-1,idens))*g_zone

     if (dpdr /= ZERO .and. model_hse(i+1,idens) > low_density_cutoff) then
        max_hse_error = max(max_hse_error, abs(dpdr - rhog)/abs(dpdr))
     endif

     if (dpdr /= 0) then
        print *, i, real(model_hse(i,idens)), real(model_hse(i,itemp)), real(dpdr), real(rhog), abs(dpdr - rhog)/abs(dpdr)
     endif
  enddo

  print *, 'maximum HSE error = ', max_hse_error
  print *, ' '


  print *, 'total mass = ', M_enclosed(i_fluff)/M_sun



  close (unit=50)

end program init_1d
