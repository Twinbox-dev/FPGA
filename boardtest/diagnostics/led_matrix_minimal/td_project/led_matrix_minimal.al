<?xml version="1.0" encoding="UTF-8"?>
<Project Version="3" Minor="2" Path="C:/Users/23506/Desktop/anlogic/boardtest/diagnostics/led_matrix_minimal/td_project">
    <Project_Created_Time></Project_Created_Time>
    <TD_Version>6.2.168116</TD_Version>
    <Name>led_matrix_minimal</Name>
    <HardWare>
        <Family>EG4</Family>
        <Device>EG4S20BG256</Device>
        <Speed></Speed>
    </HardWare>
    <Source_Files>
        <Verilog>
            <File Path="../user_source/hdl_source/top.v">
                <FileInfo><Attr Name="UsedInSyn" Val="true"/><Attr Name="UsedInP&amp;R" Val="true"/><Attr Name="BelongTo" Val="design_1"/><Attr Name="CompileOrder" Val="1"/></FileInfo>
            </File>
            <File Path="../user_source/hdl_source/is31fl3731_i2c_master.v">
                <FileInfo><Attr Name="UsedInSyn" Val="true"/><Attr Name="UsedInP&amp;R" Val="true"/><Attr Name="BelongTo" Val="design_1"/><Attr Name="CompileOrder" Val="2"/></FileInfo>
            </File>
        </Verilog>
        <ADC_FILE>
            <File Path="../user_source/constraints_source/pin.adc">
                <FileInfo><Attr Name="UsedInSyn" Val="true"/><Attr Name="UsedInP&amp;R" Val="true"/><Attr Name="BelongTo" Val="constraint_1"/><Attr Name="CompileOrder" Val="2"/></FileInfo>
            </File>
        </ADC_FILE>
        <SDC_FILE>
            <File Path="../user_source/constraints_source/timing.sdc">
                <FileInfo><Attr Name="UsedInSyn" Val="true"/><Attr Name="UsedInP&amp;R" Val="true"/><Attr Name="BelongTo" Val="constraint_1"/><Attr Name="CompileOrder" Val="1"/></FileInfo>
            </File>
        </SDC_FILE>
    </Source_Files>
    <FileSets><FileSet Name="design_1" Type="DesignFiles"/><FileSet Name="constraint_1" Type="ConstrainFiles"/></FileSets>
    <TOP_MODULE><LABEL>top</LABEL><MODULE>top</MODULE><CREATEINDEX>user</CREATEINDEX></TOP_MODULE>
    <Property></Property>
    <Device_Settings></Device_Settings>
    <Configurations></Configurations>
    <Runs>
        <Run Name="syn_1" Type="Synthesis" ConstraintSet="constraint_1" Description="" Active="true">
            <Strategy Name="Default_Synthesis_Strategy"><GateProperty><map_mode>area</map_mode><opt_area>high</opt_area><pack_effort>high</pack_effort></GateProperty></Strategy>
            <UserParams></UserParams>
        </Run>
        <Run Name="phy_1" Type="PhysicalDesign" ConstraintSet="constraint_1" Description="" SynRun="syn_1" Active="true">
            <Strategy Name="Default_PhysicalDesign_Strategy"><PlaceProperty><effort>high</effort><pr_strategy>2</pr_strategy><seed>3</seed></PlaceProperty></Strategy>
            <UserParams></UserParams>
        </Run>
    </Runs>
    <Project_Settings></Project_Settings>
</Project>
