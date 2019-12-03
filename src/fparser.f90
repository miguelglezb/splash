!
! Copyright (c) 2000-2008, Roland Schmehl. All rights reserved.
!
! This software is distributable under the BSD license. See the terms of the
! BSD license in the documentation provided with this software.
!
MODULE fparser
  !------- -------- --------- --------- --------- --------- --------- --------- -------
  ! Fortran 90 function parser v1.1
  !------- -------- --------- --------- --------- --------- --------- --------- -------
  !
  ! This function parser module is intended for applications where a set of mathematical
  ! fortran-style expressions is specified at runtime and is then evaluated for a large
  ! number of variable values. This is done by compiling the set of function strings
  ! into byte code, which is interpreted efficiently for the various variable values.
  !
  ! The source code is available from http://fparser.sourceforge.net
  !
  ! Please send comments, corrections or questions to the author:
  ! Roland Schmehl <roland.schmehl@alumni.uni-karlsruhe.de>
  !
  !------- -------- --------- --------- --------- --------- --------- --------- -------
  ! The function parser concept is based on a C++ class library written by  Juha
  ! Nieminen <warp@iki.fi> available from http://warp.povusers.org/FunctionParser/
  !------- -------- --------- --------- --------- --------- --------- --------- -------
  !
  ! Modifications by D, Price for integration in SPLASH:
  !  7th Aug 2009: added checkf interface routine to check syntax without compiling code
  !                added endf routine to stop memory leaks, also called from initf if needed
  !                bug fix with error message for sqrt(-ve)
  !
  !  9th Aug 2009: added Mathematical constant recognition (pi)
  !
  ! 27th Jan 2010: check for -ve numbers to fractional powers and zero to negative power added
  !
  ! 19th Oct 2016: added Fortran 2008 intrinsic functions
  !                added optional iErrType argument for error message printing
  !
  !  5th Mar 2019: added atan2 function (and parsing of functions with two arguments)

  IMPLICIT NONE
!--modification here by D.Price: define type parameters here rather than in a separate module
  integer, parameter, public  :: rn = KIND(0.0d0)          ! Precision of real numbers
!--modification (22/6/2018), adjusted integer kind to allow more than 128 variables
  integer, parameter, private :: is = SELECTED_INT_KIND(4) ! Data type of bytecode
!--end modification

  !------- -------- --------- --------- --------- --------- --------- --------- -------
  PUBLIC                     :: initf,    & ! Initialize function parser for n functions
                                parsef,   & ! Parse single function string
                                evalf,    & ! Evaluate single function
                                checkf,   & ! Check syntax in a function string
                                endf,     & ! Clean up memory once finished
                                EvalErrMsg  ! Error message (Use only when EvalErrType>0)
  INTEGER, PUBLIC            :: EvalErrType ! =0: no error occured, >0: evaluation error
!--modification by D. Price: add parseErr parameter (used in checkf)
  INTEGER, PRIVATE           :: ParseErrType ! =0: no error occured, >0: parse error
!--modification by D. Price: add verboseness internal variable (used in checkf)
  LOGICAL, PRIVATE           :: PrintErrors = .true. ! =0: no error occured, >0: parse error
!--modification by J. Wurster: added cgs and code versions of mu0
  REAL, PUBLIC               :: mu0=1.0_rn   ! =1 for code units, 4pi for cgs
  !------- -------- --------- --------- --------- --------- --------- --------- -------
  PRIVATE
  SAVE
  INTEGER(is),                              PARAMETER :: cImmed   = 1,          &
                                                         cNeg     = 2,          &
                                                         cAdd     = 3,          &
                                                         cSub     = 4,          &
                                                         cMul     = 5,          &
                                                         cDiv     = 6,          &
                                                         cPow     = 7,          &
                                                         cAbs     = 8,          &
                                                         cExp     = 9,          &
                                                         cLog10   = 10,         &
                                                         cLog     = 11,         &
                                                         cSqrt    = 12,         &
                                                         cSinh    = 13,         &
                                                         cCosh    = 14,         &
                                                         cTanh    = 15,         &
                                                         cSin     = 16,         &
                                                         cCos     = 17,         &
                                                         cTan     = 18,         &
                                                         cAsin    = 19,         &
                                                         cAcos    = 20,         &
                                                         cAtan2   = 21,         &
                                                         cAtan    = 22,         &
                                                         cBesj0   = 23,         &
                                                         cBesj1   = 24,         &
                                                         cBesy0   = 25,         &
                                                         cBesy1   = 26,         &
                                                         cerfcs   = 27,         &
                                                         cerfc    = 28,         &
                                                         cerf     = 29,         &
                                                         cgamma   = 30,         &
                                                         VarBegin = 31
  CHARACTER (LEN=1), DIMENSION(cAdd:cPow),  PARAMETER :: Ops      = (/ '+',     &
                                                                       '-',     &
                                                                       '*',     &
                                                                       '/',     &
                                                                       '^' /)
  CHARACTER (LEN=5), DIMENSION(cAbs:cgamma), PARAMETER :: Funcs   = (/'abs  ', &
                                                                      'exp  ', &
                                                                      'log10', &
                                                                      'log  ', &
                                                                      'sqrt ', &
                                                                      'sinh ', &
                                                                      'cosh ', &
                                                                      'tanh ', &
                                                                      'sin  ', &
                                                                      'cos  ', &
                                                                      'tan  ', &
                                                                      'asin ', &
                                                                      'acos ', &
                                                                      'atan2', &
                                                                      'atan ', &
                                                                      'besj0', &
                                                                      'besj1', &
                                                                      'besy0', &
                                                                      'besy1', &
                                                                      'erfcs', &
                                                                      'erfc ', &
                                                                      'erf  ', &
                                                                      'gamf ' /)
  TYPE tComp
     INTEGER(is), DIMENSION(:), POINTER :: ByteCode
     INTEGER                            :: ByteCodeSize
     REAL(rn),    DIMENSION(:), POINTER :: Immed
     INTEGER                            :: ImmedSize
     REAL(rn),    DIMENSION(:), POINTER :: Stack
     INTEGER                            :: StackSize, &
                                           StackPtr
  END TYPE tComp
  TYPE (tComp),  DIMENSION(:),  POINTER :: Comp              ! Bytecode
  INTEGER,   DIMENSION(:),  ALLOCATABLE :: ipos              ! Associates function strings
  !
CONTAINS
  !
  SUBROUTINE initf (n)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Initialize function parser for n functions
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    INTEGER, INTENT(in) :: n                                 ! Number of functions
    INTEGER             :: i
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IF (ASSOCIATED(Comp)) THEN
       print "(a)",' fparser warning: initf called repeatedly without prior call to endf'
       CALL endf
    ENDIF
    ALLOCATE (Comp(n))
    DO i=1,n
       NULLIFY (Comp(i)%ByteCode,Comp(i)%Immed,Comp(i)%Stack)
    END DO
  END SUBROUTINE initf
  !
  SUBROUTINE endf()
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Clean up memory at the end of the function parsing/evaluation calls (D. Price)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    INTEGER             :: i
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IF (ASSOCIATED(Comp)) THEN
       DO i=1,size(Comp)
          IF (ASSOCIATED(Comp(i)%ByteCode)) DEALLOCATE ( Comp(i)%ByteCode, &
                                                         Comp(i)%Immed,    &
                                                         Comp(i)%Stack     )
       ENDDO
       DEALLOCATE(Comp)
    ENDIF
  END SUBROUTINE endf
  !
  SUBROUTINE parsef (i, FuncStr, Var, err, Verbose)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Parse ith function string FuncStr and compile it into bytecode
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    INTEGER,                         INTENT(in) :: i         ! Function identifier
    CHARACTER (LEN=*),               INTENT(in) :: FuncStr   ! Function string
    CHARACTER (LEN=*), DIMENSION(:), INTENT(in) :: Var       ! Array with variable names
    CHARACTER (LEN=LEN(FuncStr))                :: Func      ! Function string, local use
    INTEGER, INTENT(OUT), OPTIONAL              :: err
    LOGICAL, INTENT(IN), OPTIONAL               :: Verbose   ! Turn error messages on/off
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IF (i < 1 .OR. i > SIZE(Comp)) THEN
       WRITE(*,*) '*** Parser error: Function number ',i,' out of range'
       IF (present(err)) err = 1
       RETURN
    END IF
    EvalErrType  = 0   ! D. Price : to prevent accidental misuse
    ParseErrType = 0
    PrintErrors  = .true.
    IF (present(Verbose)) PrintErrors = Verbose

    ALLOCATE (ipos(LEN(Func)))                       ! Char. positions in orig. string
    Func = FuncStr                                           ! Local copy of function string
    CALL Replace ('**','^ ',Func)                            ! Exponent into 1-Char. format
    CALL RemoveSpaces (Func)                                 ! Condense function string
    !CALL GetConstants (Func)
    CALL CheckSyntax (Func,FuncStr,Var)
    DEALLOCATE (ipos)
    IF (present(err)) err = ParseErrType
    PrintErrors = .true.                                     ! reset this to true

    !--D. Price: return after ParseErr here instead of stop inside CheckSyntax
    IF (ParseErrType /= 0) RETURN
    CALL Compile (i,Func,Var)                                ! Compile into bytecode
  END SUBROUTINE parsef
  !
  INTEGER FUNCTION checkf(FuncStr, Var, Verbose)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Check syntax in a function string (added by D. Price) but do not compile it
    ! Returns an error code NOT related to ErrMsg
    ! Optional variable "verbose" determines whether or not error messages are printed
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    CHARACTER (LEN=*),               INTENT(IN) :: FuncStr   ! Function string
    CHARACTER (LEN=*), DIMENSION(:), INTENT(IN) :: Var       ! Array with variable names
    LOGICAL, INTENT(IN), OPTIONAL               :: Verbose   ! Turn error messages on/off
    CHARACTER (LEN=LEN(FuncStr))                :: Func      ! Function string, local use
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    EvalErrType  = 0   ! D. Price : to prevent accidental misuse
    ParseErrType = 0
    PrintErrors  = .true.
    IF (present(Verbose)) PrintErrors = Verbose

    ALLOCATE (ipos(LEN(Func)))                               ! Char. positions in orig. string
    Func = FuncStr                                           ! Local copy of function string
    CALL Replace ('**','^ ',Func)                            ! Exponent into 1-Char. format
    CALL RemoveSpaces (Func)                                 ! Condense function string
    !CALL GetConstants (Func)
    CALL CheckSyntax (Func,FuncStr,Var)
    DEALLOCATE (ipos)

    PrintErrors = .true.                                     ! reset this to true
    checkf = ParseErrType
  END FUNCTION checkf
  !
  FUNCTION evalf (i, Val) RESULT (res)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Evaluate bytecode of ith function for the values passed in array Val(:)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    INTEGER,                INTENT(in) :: i                  ! Function identifier
    REAL(rn), DIMENSION(:), INTENT(in) :: Val                ! Variable values
    REAL(rn)                           :: res                ! Result
    INTEGER                            :: IP,              & ! Instruction pointer
                                          DP,              & ! Data pointer
                                          SP                 ! Stack pointer
    REAL(rn),                PARAMETER :: zero = 0._rn
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    DP = 1
    SP = 0
    DO IP=1,Comp(i)%ByteCodeSize
       SELECT CASE (Comp(i)%ByteCode(IP))

       CASE (cImmed); SP=SP+1; Comp(i)%Stack(SP)=Comp(i)%Immed(DP); DP=DP+1
       CASE   (cNeg); Comp(i)%Stack(SP)=-Comp(i)%Stack(SP)
       CASE   (cAdd); Comp(i)%Stack(SP-1)=Comp(i)%Stack(SP-1)+Comp(i)%Stack(SP); SP=SP-1
       CASE   (cSub); Comp(i)%Stack(SP-1)=Comp(i)%Stack(SP-1)-Comp(i)%Stack(SP); SP=SP-1
       CASE   (cMul); Comp(i)%Stack(SP-1)=Comp(i)%Stack(SP-1)*Comp(i)%Stack(SP); SP=SP-1
       CASE   (cDiv); IF (Comp(i)%Stack(SP)==0._rn) THEN; EvalErrType=1; res=zero; RETURN; ENDIF
                      Comp(i)%Stack(SP-1)=Comp(i)%Stack(SP-1)/Comp(i)%Stack(SP); SP=SP-1
       ! D. Price: check for zero to negative powers and negative numbers to fractional powers
       CASE   (cPow); IF (Comp(i)%Stack(SP-1)==0._rn .and.Comp(i)%Stack(SP)<0._rn) &
                      THEN; EvalErrType=1; res=zero; RETURN; ENDIF
                      IF (Comp(i)%Stack(SP-1)<=0._rn .and.(Comp(i)%Stack(SP).ne.nint(Comp(i)%Stack(SP)))) &
                      THEN; EvalErrType=5; res=zero; RETURN; ENDIF
                      Comp(i)%Stack(SP-1)=Comp(i)%Stack(SP-1)**Comp(i)%Stack(SP); SP=SP-1
       CASE   (cAbs); Comp(i)%Stack(SP)=ABS(Comp(i)%Stack(SP))
       CASE   (cExp); Comp(i)%Stack(SP)=EXP(Comp(i)%Stack(SP))
       CASE (cLog10); IF (Comp(i)%Stack(SP)<=0._rn) THEN; EvalErrType=3; res=zero; RETURN; ENDIF
                      Comp(i)%Stack(SP)=LOG10(Comp(i)%Stack(SP))
       CASE   (cLog); IF (Comp(i)%Stack(SP)<=0._rn) THEN; EvalErrType=3; res=zero; RETURN; ENDIF
                      Comp(i)%Stack(SP)=LOG(Comp(i)%Stack(SP))
       CASE  (cSqrt); IF (Comp(i)%Stack(SP)<0._rn) THEN; EvalErrType=2; res=zero; RETURN; ENDIF
                      Comp(i)%Stack(SP)=SQRT(Comp(i)%Stack(SP))
       CASE  (cSinh); Comp(i)%Stack(SP)=SINH(Comp(i)%Stack(SP))
       CASE  (cCosh); Comp(i)%Stack(SP)=COSH(Comp(i)%Stack(SP))
       CASE  (cTanh); Comp(i)%Stack(SP)=TANH(Comp(i)%Stack(SP))
       CASE   (cSin); Comp(i)%Stack(SP)=SIN(Comp(i)%Stack(SP))
       CASE   (cCos); Comp(i)%Stack(SP)=COS(Comp(i)%Stack(SP))
       CASE   (cTan); Comp(i)%Stack(SP)=TAN(Comp(i)%Stack(SP))
       CASE  (cAsin); IF ((Comp(i)%Stack(SP)<-1._rn).OR.(Comp(i)%Stack(SP)>1._rn)) THEN
                      EvalErrType=4; res=zero; RETURN; ENDIF
                      Comp(i)%Stack(SP)=ASIN(Comp(i)%Stack(SP))
       CASE  (cAcos); IF ((Comp(i)%Stack(SP)<-1._rn).OR.(Comp(i)%Stack(SP)>1._rn)) THEN
                      EvalErrType=4; res=zero; RETURN; ENDIF
                      Comp(i)%Stack(SP)=ACOS(Comp(i)%Stack(SP))
       CASE  (cAtan2); Comp(i)%Stack(SP-1)=ATAN2(Comp(i)%Stack(SP-1),Comp(i)%Stack(SP)); SP=SP-1
       CASE  (cAtan); Comp(i)%Stack(SP)=ATAN(Comp(i)%Stack(SP))
       CASE  (cBesj0); Comp(i)%Stack(SP)=bessel_j0(Comp(i)%Stack(SP))
       CASE  (cBesj1); Comp(i)%Stack(SP)=bessel_j1(Comp(i)%Stack(SP))
       CASE  (cBesy0); IF (Comp(i)%Stack(SP)<=0._rn) THEN; EvalErrType=6; res=zero; RETURN; ENDIF
                       Comp(i)%Stack(SP)=bessel_y0(Comp(i)%Stack(SP))
       CASE  (cBesy1); IF (Comp(i)%Stack(SP)<=0._rn) THEN; EvalErrType=7; res=zero; RETURN; ENDIF
                       Comp(i)%Stack(SP)=bessel_y1(Comp(i)%Stack(SP))
       CASE  (cerf);   Comp(i)%Stack(SP)=erf(Comp(i)%Stack(SP))
       CASE  (cerfc);  Comp(i)%Stack(SP)=erfc(Comp(i)%Stack(SP))
       CASE  (cerfcs); Comp(i)%Stack(SP)=erfc_scaled(Comp(i)%Stack(SP))
       CASE  (cgamma); IF (Comp(i)%Stack(SP)==-abs(nint(Comp(i)%Stack(SP)))) THEN; EvalErrType=8; res=zero; RETURN; ENDIF
                       Comp(i)%Stack(SP)=gamma(Comp(i)%Stack(SP))
       CASE  DEFAULT; SP=SP+1; Comp(i)%Stack(SP)=Val(Comp(i)%ByteCode(IP)-VarBegin+1)
       END SELECT
    END DO
    EvalErrType = 0
    res = Comp(i)%Stack(1)
  END FUNCTION evalf
  !
  SUBROUTINE CheckSyntax (Func,FuncStr,Var)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Check syntax of function string,  returns 0 if syntax is ok
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    CHARACTER (LEN=*),               INTENT(in) :: Func      ! Function string without spaces
    CHARACTER (LEN=*),               INTENT(in) :: FuncStr   ! Original function string
    CHARACTER (LEN=*), DIMENSION(:), INTENT(in) :: Var       ! Array with variable names
    INTEGER(is)                                 :: n
    CHARACTER (LEN=1)                           :: c
    REAL(rn)                                    :: r
    LOGICAL                                     :: err
    INTEGER                                     :: ParCnt, & ! Parenthesis counter
                                                   j,ib,in,lFunc,inold,ibold
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    j = 1
    ParCnt = 0
    lFunc = LEN_TRIM(Func)

    step: DO
       IF (j > lFunc) THEN
          CALL ParseErrMsg (j, FuncStr)
          EXIT
       ENDIF
       c = Func(j:j)
       !-- -------- --------- --------- --------- --------- --------- --------- -------
       ! Check for valid operand (must appear)
       !-- -------- --------- --------- --------- --------- --------- --------- -------
       IF (c == '-' .OR. c == '+') THEN                      ! Check for leading - or +
          j = j+1
          IF (j > lFunc) THEN
             CALL ParseErrMsg (j, FuncStr, 'Missing operand')
             EXIT
          ENDIF
          c = Func(j:j)
          IF (ANY(c == Ops) .or. c == ',') THEN
             CALL ParseErrMsg (j, FuncStr, 'Multiple operators')
             EXIT
          ENDIF
       END IF
       n = MathFunctionIndex (Func(j:))
       IF (n > 0) THEN                                       ! Check for math function
          j = j+LEN_TRIM(Funcs(n))
          IF (j > lFunc) THEN
             CALL ParseErrMsg (j, FuncStr, 'Missing function argument')
             EXIT
          ENDIF
          c = Func(j:j)
          IF (c /= '(') THEN
             CALL ParseErrMsg (j, FuncStr, 'Missing opening parenthesis')
             EXIT
          ENDIF
          IF (n == cAtan2) THEN                              ! Check #args for function with two arguments
             IF (CountArgs(Func(j:)) /= 2) THEN
                CALL ParseErrMsg (j, FuncStr, 'Function expects two arguments')
                EXIT
             ENDIF
          ELSE
             IF (CountArgs(Func(j:)) > 1) THEN
                CALL ParseErrMsg (j, FuncStr, 'Too many function arguments')
                EXIT
             ENDIF
          ENDIF
       END IF
       IF (c == '(') THEN                                    ! Check for opening parenthesis
          ParCnt = ParCnt+1
          j = j+1
          CYCLE step
       END IF
       IF (SCAN(c,'0123456789.') > 0) THEN                   ! Check for number
          r = RealNum (Func(j:),ib,in,err)
          IF (err) THEN
             CALL ParseErrMsg (j, FuncStr, 'Invalid number format:  '//Func(j+ib-1:j+in-2))
             EXIT
          ENDIF
          j = j+in-1
          IF (j > lFunc) EXIT
          c = Func(j:j)
       ELSE                                                  ! Check for variable
          n = VariableIndex (Func(j:),Var,ib,in)
          IF (n == 0) THEN                                   ! DP: If not a variable, check for constants
             ibold = ib
             inold = in
             r = MathConst (Func(j:),ib,in,err)
             IF (err) THEN                                   ! Return error if constants not found
                CALL ParseErrMsg (j, FuncStr, 'Invalid element: '//Func(j+ib-1:j+in-2))
                ib = ibold
                in = inold
                EXIT
             ENDIF
          ENDIF
          j = j+in-1
          IF (j > lFunc) EXIT
          c = Func(j:j)
       END IF
       DO WHILE (c == ')')                                   ! Check for closing parenthesis
          ParCnt = ParCnt-1
          IF (ParCnt < 0) CALL ParseErrMsg (j, FuncStr, 'Mismatched parenthesis')
          IF (Func(j-1:j-1) == '(') CALL ParseErrMsg (j-1, FuncStr, 'Empty parentheses')
          j = j+1
          IF (j > lFunc) EXIT
          c = Func(j:j)
       END DO
       !-- -------- --------- --------- --------- --------- --------- --------- -------
       ! Now, we have a legal operand: A legal operator or end of string must follow
       !-- -------- --------- --------- --------- --------- --------- --------- -------
       IF (j > lFunc) EXIT
       IF (ANY(c == Ops) .or. c == ',') THEN                               ! Check for multiple operators
          IF (j+1 > lFunc) CALL ParseErrMsg (j, FuncStr)
          IF (ANY(Func(j+1:j+1) == Ops)) CALL ParseErrMsg (j+1, FuncStr, 'Multiple operators')
       ELSE                                                  ! Check for next operand
          CALL ParseErrMsg (j, FuncStr, 'Missing operator')
       END IF
       !-- -------- --------- --------- --------- --------- --------- --------- -------
       ! Now, we have an operand and an operator: the next loop will check for another
       ! operand (must appear)
       !-- -------- --------- --------- --------- --------- --------- --------- -------
       j = j+1
    END DO step
    IF (ParCnt > 0) CALL ParseErrMsg (j, FuncStr, 'Missing )')
  END SUBROUTINE CheckSyntax
  !
  FUNCTION EvalErrMsg ( ierrType ) RESULT (msg)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Return error message
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    CHARACTER (LEN=*), DIMENSION(8), PARAMETER :: m = (/ 'Division by zero                   ', &
                                                         'Argument of SQRT negative          ', &
                                                         'Argument of LOG <= 0               ', &
                                                         'Argument of ASIN or ACOS illegal   ', &
                                                         '-ve number to fractional power     ', &
                                                         'Argument of Bessel_y0 <= 0         ', &
                                                         'Argument of Bessel_y1 <= 0         ', &
                                                         'Argument of Gamma function illegal '/)
    CHARACTER (LEN=LEN(m))                     :: msg
    INTEGER,  INTENT(in), OPTIONAL :: ierrType
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IF (present(ierrType)) THEN
       IF (iErrType < 1 .OR. iErrType > SIZE(m)) THEN
          msg = ''
       ELSE
          msg = m(iErrType)
       ENDIF
    ELSE
       IF (EvalErrType < 1 .OR. EvalErrType > SIZE(m)) THEN
          msg = ''
       ELSE
          msg = m(EvalErrType)
       ENDIF
    ENDIF
  END FUNCTION EvalErrMsg
  !
  SUBROUTINE ParseErrMsg (j, FuncStr, Msg)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Print error message (modification by D.Price: do not terminate program,
    !                      also added option to not print error message)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    INTEGER,                     INTENT(in) :: j
    CHARACTER (LEN=*),           INTENT(in) :: FuncStr       ! Original function string
    CHARACTER (LEN=*), OPTIONAL, INTENT(in) :: Msg
    INTEGER                                 :: k
    !----- -------- --------- --------- --------- --------- --------- --------- -------

    IF (PrintErrors) THEN
       IF (PRESENT(Msg)) THEN
          WRITE(*,*) '*** Error in syntax of function string: '//Msg
       ELSE
          WRITE(*,*) '*** Error in syntax of function string:'
       ENDIF
       WRITE(*,*)
       WRITE(*,'(A)') ' '//FuncStr
       IF (ALLOCATED(ipos)) THEN                               ! Avoid out-of-bounds-errors
          IF (SIZE(ipos).ge.j) THEN
             DO k=1,ipos(j)
                WRITE(*,'(A)',ADVANCE='NO') ' '                ! Advance to the jth position
             END DO
             WRITE(*,'(A)') '?'
          ENDIF
       ENDIF
    ENDIF
    ParseErrType = 1

  END SUBROUTINE ParseErrMsg
  !
  FUNCTION OperatorIndex (c) RESULT (n)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Return operator index
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    CHARACTER (LEN=1), INTENT(in) :: c
    INTEGER(is)                   :: n,j
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    n = 0
    DO j=cAdd,cPow
       IF (c == Ops(j)) THEN
          n = j
          EXIT
       END IF
    END DO
  END FUNCTION OperatorIndex
  !
  FUNCTION MathFunctionIndex (str) RESULT (n)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Return index of math function beginnig at 1st position of string str
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    CHARACTER (LEN=*), INTENT(in) :: str
    INTEGER(is)                   :: n,j
    INTEGER                       :: k
    CHARACTER (LEN=LEN(Funcs))    :: fun
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    n = 0
    DO j=cAbs,cgamma                                         ! Check all math functions
       k = MIN(LEN_TRIM(Funcs(j)), LEN(str))
       CALL LowCase (str(1:k), fun)
       IF (fun == Funcs(j)) THEN                             ! Compare lower case letters
          n = j                                              ! Found a matching function
          EXIT
       END IF
    END DO
  END FUNCTION MathFunctionIndex
  !
  FUNCTION VariableIndex (str, Var, ibegin, inext) RESULT (n)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Return index of variable at begin of string str (returns 0 if no variable found)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    CHARACTER (LEN=*),               INTENT(in) :: str       ! String
    CHARACTER (LEN=*), DIMENSION(:), INTENT(in) :: Var       ! Array with variable names
    INTEGER(is)                                 :: n,j       ! Index of variable
    INTEGER, OPTIONAL,              INTENT(out) :: ibegin, & ! Start position of variable name
                                                   inext     ! Position of character after name
    INTEGER                                     :: ib,in,lstr
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    n = 0
    lstr = LEN_TRIM(str)
    IF (lstr > 0) THEN
       DO ib=1,lstr                                          ! Search for first character in str
          IF (str(ib:ib) /= ' ') EXIT                        ! When lstr>0 at least 1 char in str
       END DO
       DO in=ib,lstr                                         ! Search for name terminators
          IF (SCAN(str(in:in),'+-*/^,) ') > 0) EXIT
       END DO
       DO j=1,SIZE(Var,kind=is)
          IF (str(ib:in-1) == Var(j)) THEN
             n = j                                           ! Variable name found
             EXIT
          END IF
       END DO
    !--else below added by D. Price - should never be required though
    ELSE                                                     ! blank string
       ib = 1  ! to avoid compiler warnings
       in = 2  ! and any possible seg fault
    END IF
    IF (PRESENT(ibegin)) ibegin = ib
    IF (PRESENT(inext))  inext  = in
  END FUNCTION VariableIndex
  !
  SUBROUTINE RemoveSpaces (str)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Remove Spaces from string, remember positions of characters in old string
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    CHARACTER (LEN=*), INTENT(inout) :: str
    INTEGER                          :: k,lstr
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    lstr = LEN_TRIM(str)
    ipos = 0
    do k=1,lstr
       ipos(k) = k
    enddo
    k = 1
    DO WHILE (str(k:lstr) /= ' ')
       IF (str(k:k) == ' ') THEN
          str(k:lstr)  = str(k+1:lstr)//' '                  ! Move 1 character to left
          ipos(k:lstr) = (/ ipos(k+1:lstr), 0 /)             ! Move 1 element to left
          k = k-1
       END IF
       k = k+1
    END DO
  END SUBROUTINE RemoveSpaces
  !
  SUBROUTINE Replace (ca,cb,str)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Replace ALL appearances of character set ca in string str by character set cb
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    CHARACTER (LEN=*),       INTENT(in) :: ca
    CHARACTER (LEN=LEN(ca)), INTENT(in) :: cb                ! LEN(ca) must be LEN(cb)
    CHARACTER (LEN=*),    INTENT(inout) :: str
    INTEGER                             :: j,lca
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    lca = LEN(ca)
    DO j=1,LEN_TRIM(str)-lca+1
       IF (str(j:j+lca-1) == ca) str(j:j+lca-1) = cb
    END DO
  END SUBROUTINE Replace
  !
  FUNCTION CountArgs(str) RESULT(n)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Count number of arguments in a function string
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    CHARACTER (LEN=*), INTENT(in) :: str
    INTEGER                       :: n,j
    n = 1
    DO j=1,len_trim(str)
       if (str(j:j) == ',') n = n + 1
    ENDDO
  END FUNCTION CountArgs
  !
  SUBROUTINE Compile (i, F, Var)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Compile i-th function string F into bytecode
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    INTEGER,                         INTENT(in) :: i         ! Function identifier
    CHARACTER (LEN=*),               INTENT(in) :: F         ! Function string
    CHARACTER (LEN=*), DIMENSION(:), INTENT(in) :: Var       ! Array with variable names
    INTEGER                                     :: istat
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IF (ASSOCIATED(Comp(i)%ByteCode)) DEALLOCATE ( Comp(i)%ByteCode, &
                                                   Comp(i)%Immed,    &
                                                   Comp(i)%Stack     )
    Comp(i)%ByteCodeSize = 0
    Comp(i)%ImmedSize    = 0
    Comp(i)%StackSize    = 0
    Comp(i)%StackPtr     = 0
    CALL CompileSubstr (i,F,1,LEN_TRIM(F),Var)               ! Compile string to determine size
    ALLOCATE ( Comp(i)%ByteCode(Comp(i)%ByteCodeSize), &
               Comp(i)%Immed(Comp(i)%ImmedSize),       &
               Comp(i)%Stack(Comp(i)%StackSize),       &
               STAT = istat                            )
    IF (istat /= 0) THEN
       WRITE(*,*) '*** Parser error: Memory allocation for byte code failed'
       STOP
    ELSE
       Comp(i)%ByteCodeSize = 0
       Comp(i)%ImmedSize    = 0
       Comp(i)%StackSize    = 0
       Comp(i)%StackPtr     = 0
       CALL CompileSubstr (i,F,1,LEN_TRIM(F),Var)            ! Compile string into bytecode
    END IF
    !
  END SUBROUTINE Compile
  !
  SUBROUTINE AddCompiledByte (i, b)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Add compiled byte to bytecode
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    INTEGER,     INTENT(in) :: i                             ! Function identifier
    INTEGER(is), INTENT(in) :: b                             ! Value of byte to be added
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    Comp(i)%ByteCodeSize = Comp(i)%ByteCodeSize + 1
    IF (ASSOCIATED(Comp(i)%ByteCode)) Comp(i)%ByteCode(Comp(i)%ByteCodeSize) = b
  END SUBROUTINE AddCompiledByte
  !
  FUNCTION MathItemIndex (i, F, Var) RESULT (n)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Return math item index, if item is real number, enter it into Comp-structure
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    INTEGER,                         INTENT(in) :: i         ! Function identifier
    CHARACTER (LEN=*),               INTENT(in) :: F         ! Function substring
    CHARACTER (LEN=*), DIMENSION(:), INTENT(in) :: Var       ! Array with variable names
    INTEGER(is)                                 :: n         ! Byte value of math item
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    n = 0
    IF (SCAN(F(1:1),'0123456789.') > 0) THEN                 ! Check for begin of a number
       Comp(i)%ImmedSize = Comp(i)%ImmedSize + 1
       IF (ASSOCIATED(Comp(i)%Immed)) Comp(i)%Immed(Comp(i)%ImmedSize) = RealNum (F)
       n = cImmed
    ELSE                                                     ! Check for a variable
       n = VariableIndex (F, Var)
       IF (n > 0) THEN
          n = VarBegin+n-1_is
       ELSE   ! Check for Mathematical constants
          n = MathConstIndex(i, F)
       ENDIF
    END IF
  END FUNCTION MathItemIndex
  !
  FUNCTION MathConstIndex (i, F, ibegin, inext) RESULT (n)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Routine added by D. Price
    ! Substitute values for Mathematical Constants (e.g. pi)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    INTEGER,                         INTENT(in) :: i         ! Function identifier
    CHARACTER (LEN=*),               INTENT(in) :: F         ! Function substring
    INTEGER, OPTIONAL,              INTENT(out) :: ibegin, & ! Start position of real number
                                                   inext     ! 1st character after real number
    INTEGER(is)                                 :: n         ! Byte value of math item
    REAL(rn)                                    :: res
    LOGICAL                                     :: err
    INTEGER                                     :: ib,in
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    n = 0
    res = MathConst(F,ib,in,err)
    IF (.not.err) THEN
       Comp(i)%ImmedSize = Comp(i)%ImmedSize + 1
       IF (ASSOCIATED(Comp(i)%Immed)) Comp(i)%Immed(Comp(i)%ImmedSize) = res
       n = cImmed
    ELSE
       ib = 1
       in = 1
    END IF
    IF (PRESENT(ibegin)) ibegin = ib
    IF (PRESENT(inext))  inext  = in

  END FUNCTION MathConstIndex
  !
  FUNCTION CompletelyEnclosed (F, b, e) RESULT (res)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Check if function substring F(b:e) is completely enclosed by a pair of parenthesis
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    CHARACTER (LEN=*), INTENT(in) :: F                       ! Function substring
    INTEGER,           INTENT(in) :: b,e                     ! First and last pos. of substring
    LOGICAL                       :: res
    INTEGER                       :: j,k
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    res=.false.
    IF (F(b:b) == '(' .AND. F(e:e) == ')') THEN
       k = 0
       DO j=b+1,e-1
          IF     (F(j:j) == '(') THEN
             k = k+1
          ELSEIF (F(j:j) == ')') THEN
             k = k-1
          END IF
          IF (k < 0) EXIT
       END DO
       IF (k == 0) res=.true.                                ! All opened parenthesis closed
    END IF
  END FUNCTION CompletelyEnclosed

  FUNCTION TwoArgs (F, b, e, m) RESULT (res)
   !----- -------- --------- --------- --------- --------- --------- --------- -------
   ! Check if function substring F(b:e) has two arguments i.e. f(a,b)
   !----- -------- --------- --------- --------- --------- --------- --------- -------
   IMPLICIT NONE
   CHARACTER (LEN=*), INTENT(in) :: F                       ! Function substring
   INTEGER,           INTENT(in) :: b,e                     ! First and last pos. of substring
   INTEGER,           INTENT(out) :: m
   LOGICAL                       :: res

   res = .false.
   m = INDEX(F(b:e),',')
   IF (m > 0) THEN
      res = .true.
      m = b + m - 1
   ENDIF

  END FUNCTION TwoArgs
  !
  RECURSIVE SUBROUTINE CompileSubstr (i, F, b, e, Var)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Compile i-th function string F into bytecode
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    INTEGER,                         INTENT(in) :: i         ! Function identifier
    CHARACTER (LEN=*),               INTENT(in) :: F         ! Function substring
    INTEGER,                         INTENT(in) :: b,e       ! Begin and end position substring
    CHARACTER (LEN=*), DIMENSION(:), INTENT(in) :: Var       ! Array with variable names
    INTEGER(is)                                 :: n
    INTEGER                                     :: b2,j,k,io,m
    CHARACTER (LEN=*),                PARAMETER :: calpha = 'abcdefghijklmnopqrstuvwxyz'// &
                                                            'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Check for special cases of substring
    !----- -------- --------- --------- --------- --------- --------- --------- -------
!      WRITE(*,*) 'PARSING F(b:e) = '//F(b:e)
    IF     (F(b:b) == '+') THEN                              ! Case 1: F(b:e) = '+...'
!      WRITE(*,*)'1. F(b:e) = "+..."'
       CALL CompileSubstr (i, F, b+1, e, Var)
       RETURN
    ELSEIF (CompletelyEnclosed (F, b, e)) THEN               ! Case 2: F(b:e) = '(...)'
!      WRITE(*,*)'2. F(b:e) = "(...)"'
       CALL CompileSubstr (i, F, b+1, e-1, Var)
       RETURN
    ELSEIF (SCAN(F(b:b),calpha) > 0) THEN
       n = MathFunctionIndex (F(b:e))
       IF (n > 0) THEN
          b2 = b+INDEX(F(b:e),'(')-1
          IF (CompletelyEnclosed(F, b2, e)) THEN             ! Case 3: F(b:e) = 'fcn(...)'
!            WRITE(*,*)'3. F(b:e) = "fcn(...)"'
             IF (n == cAtan2 .and. TwoArgs(F,b2+1,e-1,m)) THEN
!                print*,' SPLITTING ',b,m,e,' F(b:e)=',F(b2+1:e-1)
                CALL CompileSubstr (i, F, b2+1, m-1, Var)
                CALL CompileSubstr (i, F, m+1, e-1, Var)
             ELSE
                CALL CompileSubstr(i, F, b2+1, e-1, Var)
             ENDIF
             CALL AddCompiledByte (i, n)
             RETURN
          END IF
       END IF
    ELSEIF (F(b:b) == '-') THEN
       IF (CompletelyEnclosed (F, b+1, e)) THEN              ! Case 4: F(b:e) = '-(...)'
!         WRITE(*,*)'4. F(b:e) = "-(...)"'
          CALL CompileSubstr (i, F, b+2, e-1, Var)
          CALL AddCompiledByte (i, cNeg)
          RETURN
       ELSEIF (SCAN(F(b+1:b+1),calpha) > 0) THEN
          n = MathFunctionIndex (F(b+1:e))
          IF (n > 0) THEN
             b2 = b+INDEX(F(b+1:e),'(')
             IF (CompletelyEnclosed(F, b2, e)) THEN          ! Case 5: F(b:e) = '-fcn(...)'
!               WRITE(*,*)'5. F(b:e) = "-fcn(...)"'
                IF (n == cAtan2 .and. TwoArgs(F,b2+1,e-1,m)) THEN
                   CALL CompileSubstr (i, F, b2+1, m-1, Var)
                   CALL CompileSubstr (i, F, m+1, e-1, Var)
                ELSE
                   CALL CompileSubstr(i, F, b2+1, e-1, Var)
                ENDIF
                CALL AddCompiledByte (i, n)
                CALL AddCompiledByte (i, cNeg)
                RETURN
             END IF
          END IF
       ENDIF
    ENDIF
!   WRITE(*,*) 'PROCEED TO OPERATORS',TwoArgs(F,b,e,m),F(b:e)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Check for operator in substring: check only base level (k=0), exclude expr. in ()
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    DO io=cAdd,cPow                                          ! Increasing priority +-*/^
       k = 0
       DO j=e,b,-1
          IF     (F(j:j) == ')') THEN
             k = k+1
          ELSEIF (F(j:j) == '(') THEN
             k = k-1
          END IF
          IF (k == 0 .AND. F(j:j) == Ops(io) .AND. IsBinaryOp (j, F)) THEN
             IF (ANY(F(j:j) == Ops(cMul:cPow)) .AND. F(b:b) == '-') THEN ! Case 6: F(b:e) = '-...Op...' with Op > -
!               WRITE(*,*)'6. F(b:e) = "-...Op..." with Op > -'
                CALL CompileSubstr (i, F, b+1, e, Var)
                CALL AddCompiledByte (i, cNeg)
                RETURN
             ELSE                                                        ! Case 7: F(b:e) = '...BinOp...'
!               WRITE(*,*)'7. Binary operator',F(j:j)
                CALL CompileSubstr (i, F, b, j-1, Var)
                CALL CompileSubstr (i, F, j+1, e, Var)
                CALL AddCompiledByte (i, OperatorIndex(Ops(io)))
                Comp(i)%StackPtr = Comp(i)%StackPtr - 1
                RETURN
             END IF
          END IF
       END DO
    END DO
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Check for remaining items, i.e. variables or explicit numbers
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    b2 = b
    IF (F(b:b) == '-') b2 = b2+1
    n = MathItemIndex(i, F(b2:e), Var)
!   WRITE(*,*)'8. AddCompiledByte ',n
    CALL AddCompiledByte (i, n)
    Comp(i)%StackPtr = Comp(i)%StackPtr + 1
    IF (Comp(i)%StackPtr > Comp(i)%StackSize) Comp(i)%StackSize = Comp(i)%StackSize + 1
    IF (b2 > b) CALL AddCompiledByte (i, cNeg)
  END SUBROUTINE CompileSubstr
  !
  FUNCTION IsBinaryOp (j, F) RESULT (res)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Check if operator F(j:j) in string F is binary operator
    ! Special cases already covered elsewhere:              (that is corrected in v1.1)
    ! - operator character F(j:j) is first character of string (j=1)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    INTEGER,           INTENT(in) :: j                       ! Position of Operator
    CHARACTER (LEN=*), INTENT(in) :: F                       ! String
    LOGICAL                       :: res                     ! Result
    INTEGER                       :: k
    LOGICAL                       :: Dflag,Pflag
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    res=.true.
    IF (F(j:j) == '+' .OR. F(j:j) == '-') THEN               ! Plus or minus sign:
       IF (j == 1) THEN                                      ! - leading unary operator ?
          res = .false.
       ELSEIF (SCAN(F(j-1:j-1),'+-*/^(') > 0) THEN           ! - other unary operator ?
          res = .false.
       ELSEIF (SCAN(F(j+1:j+1),'0123456789') > 0 .AND. &     ! - in exponent of real number ?
               SCAN(F(j-1:j-1),'eEdD')       > 0) THEN
          Dflag=.false.; Pflag=.false.
          k = j-1
          DO WHILE (k > 1)                                   !   step to the left in mantissa
             k = k-1
             IF     (SCAN(F(k:k),'0123456789') > 0) THEN
                Dflag=.true.
             ELSEIF (F(k:k) == '.') THEN
                IF (Pflag) THEN
                   EXIT                                      !   * EXIT: 2nd appearance of '.'
                ELSE
                   Pflag=.true.                              !   * mark 1st appearance of '.'
                ENDIF
             ELSE
                EXIT                                         !   * all other characters
             END IF
          END DO
          IF (Dflag .AND. (k == 1 .OR. SCAN(F(k:k),'+-*/^(') > 0)) res = .false.
       END IF
    END IF
  END FUNCTION IsBinaryOp
  !
  FUNCTION RealNum (str, ibegin, inext, error) RESULT (res)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Get real number from string - Format: [blanks][+|-][nnn][.nnn][e|E|d|D[+|-]nnn]
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    CHARACTER (LEN=*),  INTENT(in) :: str                    ! String
    REAL(rn)                       :: res                    ! Real number
    INTEGER, OPTIONAL, INTENT(out) :: ibegin,              & ! Start position of real number
                                      inext                  ! 1st character after real number
    LOGICAL, OPTIONAL, INTENT(out) :: error                  ! Error flag
    INTEGER                        :: ib,in,istat
    LOGICAL                        :: Bflag,               & ! .T. at begin of number in str
                                      InMan,               & ! .T. in mantissa of number
                                      Pflag,               & ! .T. after 1st '.' encountered
                                      Eflag,               & ! .T. at exponent identifier 'eEdD'
                                      InExp,               & ! .T. in exponent of number
                                      DInMan,              & ! .T. if at least 1 digit in mant.
                                      DInExp,              & ! .T. if at least 1 digit in exp.
                                      err                    ! Local error flag
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    Bflag=.true.; InMan=.false.; Pflag=.false.; Eflag=.false.; InExp=.false.
    DInMan=.false.; DInExp=.false.
    ib   = 1
    in   = 1
    DO WHILE (in <= LEN_TRIM(str))
       SELECT CASE (str(in:in))
       CASE (' ')                                            ! Only leading blanks permitted
          ib = ib+1
          IF (InMan .OR. Eflag .OR. InExp) EXIT
       CASE ('+','-')                                        ! Permitted only
          IF     (Bflag) THEN
             InMan=.true.; Bflag=.false.                     ! - at beginning of mantissa
          ELSEIF (Eflag) THEN
             InExp=.true.; Eflag=.false.                     ! - at beginning of exponent
          ELSE
             EXIT                                            ! - otherwise STOP
          ENDIF
       CASE ('0':'9')                                        ! Mark
          IF     (Bflag) THEN
             InMan=.true.; Bflag=.false.                     ! - beginning of mantissa
          ELSEIF (Eflag) THEN
             InExp=.true.; Eflag=.false.                     ! - beginning of exponent
          ENDIF
          IF (InMan) DInMan=.true.                           ! Mantissa contains digit
          IF (InExp) DInExp=.true.                           ! Exponent contains digit
       CASE ('.')
          IF     (Bflag) THEN
             Pflag=.true.                                    ! - mark 1st appearance of '.'
             InMan=.true.; Bflag=.false.                     !   mark beginning of mantissa
          ELSEIF (InMan .AND..NOT.Pflag) THEN
             Pflag=.true.                                    ! - mark 1st appearance of '.'
          ELSE
             EXIT                                            ! - otherwise STOP
          END IF
       CASE ('e','E','d','D')                                ! Permitted only
          IF (InMan) THEN
             Eflag=.true.; InMan=.false.                     ! - following mantissa
          ELSE
             EXIT                                            ! - otherwise STOP
          ENDIF
       CASE DEFAULT
          EXIT                                               ! STOP at all other characters
       END SELECT
       in = in+1
    END DO
    err = (ib > in-1) .OR. (.NOT.DInMan) .OR. ((Eflag.OR.InExp).AND..NOT.DInExp)
    IF (err) THEN
       res = 0.0_rn
    ELSE
       READ(str(ib:in-1),*,IOSTAT=istat) res
       err = istat /= 0
    END IF
    IF (PRESENT(ibegin)) ibegin = ib
    IF (PRESENT(inext))  inext  = in
    IF (PRESENT(error))  error  = err
  END FUNCTION RealNum

  !
  FUNCTION MathConst (str, ibegin, inext, error) RESULT (res)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Return values of Mathematical constants in string
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    CHARACTER (LEN=*),  INTENT(in) :: str                    ! String
    REAL(rn)                       :: res                    ! Real number
    INTEGER, OPTIONAL, INTENT(out) :: ibegin,              & ! Start position of real number
                                      inext                  ! 1st character after real number
    LOGICAL, OPTIONAL, INTENT(out) :: error                  ! Error flag
    INTEGER                        :: ib,in
    LOGICAL                        :: err                    ! Local error flag
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ib = 1
    in = 1
    err = .false.
    IF (len(str) < 2) THEN
       res = 0.0_rn
       err = .true.
    ELSE
       IF (str(1:2)=='pi') THEN
          res = 3.14159265358979323846_rn
          in = 3
       ELSEIF (str(1:2)=='mu') THEN
          res = mu0
          in = 3
       ELSE
          res = 0.0_rn
          err = .true.
       ENDIF
    ENDIF

    IF (PRESENT(ibegin)) ibegin = ib
    IF (PRESENT(inext))  inext  = in
    IF (PRESENT(error))  error  = err

  END FUNCTION MathConst

  !
  SUBROUTINE LowCase (str1, str2)
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    ! Transform upper case letters in str1 into lower case letters, result is str2
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    IMPLICIT NONE
    CHARACTER (LEN=*),  INTENT(in) :: str1
    CHARACTER (LEN=*), INTENT(out) :: str2
    INTEGER                        :: j,k
    CHARACTER (LEN=*),   PARAMETER :: lc = 'abcdefghijklmnopqrstuvwxyz'
    CHARACTER (LEN=*),   PARAMETER :: uc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    !----- -------- --------- --------- --------- --------- --------- --------- -------
    str2 = str1
    DO j=1,LEN_TRIM(str1)
       k = INDEX(uc,str1(j:j))
       IF (k > 0) str2(j:j) = lc(k:k)
    END DO
  END SUBROUTINE LowCase
  !
END MODULE fparser
